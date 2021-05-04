// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:kernel/ast.dart';
import 'package:kernel/clone.dart' show CloneVisitorNotMembers;
import 'package:kernel/core_types.dart' show CoreTypes;
import 'package:kernel/library_index.dart' show LibraryIndex;

import 'utils.dart';

/// Tracks used getters and setters of generated protobuf message
/// classes and prunes metadata declarations.
class ProtobufHandler {
  static const String protobufLibraryUri = 'package:protobuf/protobuf.dart';
  static const String metadataFieldName = '_i';

  // All of those methods have the dart field name as second positional
  // parameter.
  // Method names are defined in:
  // https://github.com/dart-lang/protobuf/blob/master/protobuf/lib/src/protobuf/builder_info.dart
  // The code is generated by:
  // https://github.com/dart-lang/protobuf/blob/master/protoc_plugin/lib/protobuf_field.dart.
  static const Set<String> fieldAddingMethods = const <String>{
    'a',
    'aOM',
    'aOS',
    'aQM',
    'pPS',
    'aQS',
    'aInt64',
    'aOB',
    'e',
    'p',
    'pc',
    'm',
  };

  final CoreTypes coreTypes;
  final Class _generatedMessageClass;
  final Class _tagNumberClass;
  final Field _tagNumberField;
  final Class _builderInfoClass;
  final Procedure _builderInfoAddMethod;
  final _messageClasses = <Class, _MessageClass>{};
  final _invalidatedClasses = <_MessageClass>{};

  /// Creates [ProtobufHandler] instance for [component].
  /// Returns null if protobuf library is not used.
  static ProtobufHandler forComponent(
      Component component, CoreTypes coreTypes) {
    final libraryIndex = LibraryIndex(component, [protobufLibraryUri]);
    if (!libraryIndex.containsLibrary(protobufLibraryUri)) {
      return null;
    }
    return ProtobufHandler._internal(libraryIndex, coreTypes);
  }

  ProtobufHandler._internal(LibraryIndex libraryIndex, this.coreTypes)
      : _generatedMessageClass =
            libraryIndex.getClass(protobufLibraryUri, 'GeneratedMessage'),
        _tagNumberClass =
            libraryIndex.getClass(protobufLibraryUri, 'TagNumber'),
        _tagNumberField = libraryIndex.getMember(
            protobufLibraryUri, 'TagNumber', 'tagNumber'),
        _builderInfoClass =
            libraryIndex.getClass(protobufLibraryUri, 'BuilderInfo'),
        _builderInfoAddMethod =
            libraryIndex.getMember(protobufLibraryUri, 'BuilderInfo', 'add');

  /// This method is called from summary collector when analysis discovered
  /// that [member] is called and needs to construct a summary for its body.
  ///
  /// At this point protobuf handler can
  ///  - modify static field initializer of metadata field;
  ///  - track used members of the generated message classes.
  void beforeSummaryCreation(Member member) {
    // Only interested in members of subclasses of GeneratedMessage class.
    final cls = member.enclosingClass;
    if (cls == null || cls.superclass != _generatedMessageClass) {
      return;
    }
    final messageClass = (_messageClasses[cls] ??= _MessageClass());
    if (member is Field && member.name.text == metadataFieldName) {
      // Update contents of static field initializer of metadata field (_i).
      // according to the used tag numbers.
      assert(member.isStatic);
      if (messageClass._metadataField == null) {
        messageClass._metadataField = member;
        ++Statistics.protobufMessagesUsed;
      } else {
        assert(messageClass._metadataField == member);
      }
      _updateMetadataField(messageClass);
      return;
    }
    if (member is Procedure && !member.isStatic) {
      // Track usage of accessors of protobuf fields: extract tag number
      // from annotations and add tag number to the set of used tags.
      // This may also add message class to the set of invalidated classes,
      // so their metadata field initializers will be revisited.
      for (var annotation in member.annotations) {
        final constant = (annotation as ConstantExpression).constant;
        if (constant is InstanceConstant &&
            constant.classReference == _tagNumberClass.reference) {
          if (messageClass._usedTags.add((constant
                  .fieldValues[_tagNumberField.getterReference] as IntConstant)
              .value)) {
            _invalidatedClasses.add(messageClass);
          }
        }
      }
    }
  }

  List<Field> getInvalidatedFields() {
    final fields = <Field>[];
    for (var cls in _invalidatedClasses) {
      if (cls._metadataField != null) {
        fields.add(cls._metadataField);
      }
    }
    _invalidatedClasses.clear();
    return fields;
  }

  /// Updates initializer of metadata field of [cls] message class.
  void _updateMetadataField(_MessageClass cls) {
    ++Statistics.protobufMetadataInitializersUpdated;
    Statistics.protobufMetadataFieldsPruned -= cls.numberOfFieldsPruned;

    final field = cls._metadataField;
    if (cls._originalInitializer == null) {
      cls._originalInitializer = field.initializer;
    }
    final cloner = CloneVisitorNotMembers();
    field.initializer = cloner.clone(cls._originalInitializer)..parent = field;
    final transformer = _MetadataTransformer(this, cls);
    field.initializer.accept(transformer);
    _invalidatedClasses.remove(cls);

    cls.numberOfFieldsPruned = transformer.numberOfFieldsPruned;
    Statistics.protobufMetadataFieldsPruned += cls.numberOfFieldsPruned;
  }

  bool _isUnusedMetadataMethodInvocation(
      _MessageClass cls, MethodInvocation node) {
    if (node.interfaceTarget != null &&
        node.interfaceTarget.enclosingClass == _builderInfoClass &&
        fieldAddingMethods.contains(node.name.text)) {
      final tagNumber = (node.arguments.positional[0] as IntLiteral).value;
      return !cls._usedTags.contains(tagNumber);
    }
    return false;
  }

  bool _isUnusedMetadata(_MessageClass cls, InstanceInvocation node) {
    if (node.interfaceTarget.enclosingClass == _builderInfoClass &&
        fieldAddingMethods.contains(node.name.text)) {
      final tagNumber = (node.arguments.positional[0] as IntLiteral).value;
      return !cls._usedTags.contains(tagNumber);
    }
    return false;
  }
}

class _MessageClass {
  Field _metadataField;
  Expression _originalInitializer;
  final _usedTags = <int>{};
  int numberOfFieldsPruned = 0;
}

class _MetadataTransformer extends Transformer {
  final ProtobufHandler ph;
  final _MessageClass cls;
  int numberOfFieldsPruned = 0;

  _MetadataTransformer(this.ph, this.cls);

  @override
  TreeNode visitMethodInvocation(MethodInvocation node) {
    if (!ph._isUnusedMetadataMethodInvocation(cls, node)) {
      super.visitMethodInvocation(node);
      return node;
    }
    // Replace the field metadata method with a dummy call to
    // `BuilderInfo.add`. This is to preserve the index calculations when
    // removing a field.
    // Change the tag-number to 0. Otherwise the decoder will get confused.
    ++numberOfFieldsPruned;
    return MethodInvocation(
        node.receiver,
        ph._builderInfoAddMethod.name,
        Arguments(
          <Expression>[
            IntLiteral(0), // tagNumber
            NullLiteral(), // name
            NullLiteral(), // fieldType
            NullLiteral(), // defaultOrMaker
            NullLiteral(), // subBuilder
            NullLiteral(), // valueOf
            NullLiteral(), // enumValues
          ],
          types: <DartType>[const NullType()],
        ),
        ph._builderInfoAddMethod)
      ..fileOffset = node.fileOffset;
  }

  @override
  TreeNode visitInstanceInvocation(InstanceInvocation node) {
    if (!ph._isUnusedMetadata(cls, node)) {
      super.visitInstanceInvocation(node);
      return node;
    }
    // Replace the field metadata method with a dummy call to
    // `BuilderInfo.add`. This is to preserve the index calculations when
    // removing a field.
    // Change the tag-number to 0. Otherwise the decoder will get confused.
    ++numberOfFieldsPruned;
    return MethodInvocation(
        node.receiver,
        ph._builderInfoAddMethod.name,
        Arguments(
          <Expression>[
            IntLiteral(0), // tagNumber
            NullLiteral(), // name
            NullLiteral(), // fieldType
            NullLiteral(), // defaultOrMaker
            NullLiteral(), // subBuilder
            NullLiteral(), // valueOf
            NullLiteral(), // enumValues
          ],
          types: <DartType>[const NullType()],
        ),
        ph._builderInfoAddMethod)
      ..fileOffset = node.fileOffset;
  }
}
