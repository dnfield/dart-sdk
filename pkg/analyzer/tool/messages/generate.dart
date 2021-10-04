// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// This file contains code to generate scanner and parser message
/// based on the information in pkg/front_end/messages.yaml.
///
/// For each message in messages.yaml that contains an 'index:' field,
/// this tool generates an error with the name specified by the 'analyzerCode:'
/// field and an entry in the fastaAnalyzerErrorList for that generated error.
/// The text in the 'analyzerCode:' field must contain the name of the class
/// containing the error and the name of the error separated by a `.`
/// (e.g. ParserErrorCode.EQUALITY_CANNOT_BE_EQUALITY_OPERAND).
///
/// It is expected that 'pkg/front_end/tool/fasta generate-messages'
/// has already been successfully run.
import 'dart:convert';
import 'dart:io';

import 'package:_fe_analyzer_shared/src/scanner/scanner.dart';
import 'package:analyzer_utilities/package_root.dart' as pkg_root;
import 'package:analyzer_utilities/tools.dart';
import 'package:path/path.dart';
import 'package:yaml/yaml.dart' show loadYaml;

import 'error_code_info.dart';

main() async {
  await GeneratedContent.generateAll(analyzerPkgPath, allTargets);

  _SyntacticErrorGenerator()
    ..checkForManualChanges()
    ..printSummary();
}

/// Information about all the classes derived from `ErrorCode` that should be
/// generated.
const List<_ErrorClassInfo> _errorClasses = [
  _ErrorClassInfo(
      filePath: 'lib/src/analysis_options/error/option_codes.g.dart',
      name: 'AnalysisOptionsErrorCode',
      type: 'COMPILE_TIME_ERROR',
      severity: 'ERROR'),
  _ErrorClassInfo(
      filePath: 'lib/src/analysis_options/error/option_codes.g.dart',
      name: 'AnalysisOptionsHintCode',
      type: 'HINT',
      severity: 'INFO'),
  _ErrorClassInfo(
      filePath: 'lib/src/analysis_options/error/option_codes.g.dart',
      name: 'AnalysisOptionsWarningCode',
      type: 'STATIC_WARNING',
      severity: 'WARNING'),
  _ErrorClassInfo(
      filePath: 'lib/src/error/codes.g.dart',
      name: 'CompileTimeErrorCode',
      superclass: 'AnalyzerErrorCode',
      type: 'COMPILE_TIME_ERROR',
      extraImports: ['package:analyzer/src/error/analyzer_error_code.dart']),
  _ErrorClassInfo(
      filePath: 'lib/src/error/codes.g.dart',
      name: 'LanguageCode',
      type: 'COMPILE_TIME_ERROR'),
  _ErrorClassInfo(
      filePath: 'lib/src/error/codes.g.dart',
      name: 'StaticWarningCode',
      superclass: 'AnalyzerErrorCode',
      type: 'STATIC_WARNING',
      severity: 'WARNING',
      extraImports: ['package:analyzer/src/error/analyzer_error_code.dart']),
  _ErrorClassInfo(
      filePath: 'lib/src/dart/error/ffi_code.g.dart',
      name: 'FfiCode',
      superclass: 'AnalyzerErrorCode',
      type: 'COMPILE_TIME_ERROR',
      extraImports: ['package:analyzer/src/error/analyzer_error_code.dart']),
  _ErrorClassInfo(
      filePath: 'lib/src/dart/error/hint_codes.g.dart',
      name: 'HintCode',
      superclass: 'AnalyzerErrorCode',
      type: 'HINT',
      extraImports: ['package:analyzer/src/error/analyzer_error_code.dart']),
  _ErrorClassInfo(
      // TODO(paulberry): rename to `syntactic_errors.g.dart`.
      filePath: 'lib/src/dart/error/syntactic_errors.analyzer.g.dart',
      name: 'ParserErrorCode',
      type: 'SYNTACTIC_ERROR',
      severity: 'ERROR',
      includeCfeMessages: true),
  _ErrorClassInfo(
      filePath: 'lib/src/manifest/manifest_warning_code.g.dart',
      name: 'ManifestWarningCode',
      type: 'STATIC_WARNING',
      severity: 'WARNING'),
  _ErrorClassInfo(
      filePath: 'lib/src/pubspec/pubspec_warning_code.g.dart',
      name: 'PubspecWarningCode',
      type: 'STATIC_WARNING',
      severity: 'WARNING'),
];

/// A list of all targets generated by this code generator.
final List<GeneratedContent> allTargets = _analyzerGeneratedFiles();

/// The path to the `analyzer` package.
final String analyzerPkgPath =
    normalize(join(pkg_root.packageRoot, 'analyzer'));

/// The path to the `front_end` package.
final String frontEndPkgPath =
    normalize(join(pkg_root.packageRoot, 'front_end'));

/// Decoded messages from the anlayzer's `messages.yaml` file.
final Map<String, Map<String, ErrorCodeInfo>> _analyzerMessages =
    _loadAnalyzerMessages();

/// Decoded messages from the front end's `messages.yaml` file.
final Map<String, ErrorCodeInfo> _frontEndMessages = _loadFrontEndMessages();

/// Generates a list of [GeneratedContent] objects describing all the analyzer
/// files that need to be generated.
List<GeneratedContent> _analyzerGeneratedFiles() {
  var classesByFile = <String, List<_ErrorClassInfo>>{};
  for (var errorClassInfo in _errorClasses) {
    (classesByFile[errorClassInfo.filePath] ??= []).add(errorClassInfo);
  }
  return [
    for (var entry in classesByFile.entries)
      GeneratedFile(entry.key, (String pkgPath) async {
        final codeGenerator = _AnalyzerErrorGenerator(entry.value);
        codeGenerator.generate();
        return codeGenerator.out.toString();
      })
  ];
}

/// Loads analyzer messages from the analyzer's `messages.yaml` file.
Map<String, Map<String, ErrorCodeInfo>> _loadAnalyzerMessages() {
  Map<dynamic, dynamic> messagesYaml =
      loadYaml(File(join(analyzerPkgPath, 'messages.yaml')).readAsStringSync());
  return decodeAnalyzerMessagesYaml(messagesYaml);
}

/// Loads front end messages from the front end's `messages.yaml` file.
Map<String, ErrorCodeInfo> _loadFrontEndMessages() {
  Map<dynamic, dynamic> messagesYaml =
      loadYaml(File(join(frontEndPkgPath, 'messages.yaml')).readAsStringSync());
  return decodeCfeMessagesYaml(messagesYaml);
}

/// Code generator for analyzer error classes.
class _AnalyzerErrorGenerator {
  final List<_ErrorClassInfo> errorClasses;
  final CfeToAnalyzerErrorCodeTables tables =
      CfeToAnalyzerErrorCodeTables(_frontEndMessages);
  final out = StringBuffer('''
// Copyright (c) 2021, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// THIS FILE IS GENERATED. DO NOT EDIT.
//
// Instead modify 'pkg/analyzer/messages.yaml' and run
// 'dart pkg/analyzer/tool/messages/generate.dart' to update.
''');

  _AnalyzerErrorGenerator(this.errorClasses);

  void generate() {
    var imports = {'package:analyzer/error/error.dart'};
    bool shouldGenerateFastaAnalyzerErrorCodes = false;
    for (var errorClass in errorClasses) {
      imports.addAll(errorClass.extraImports);
      if (errorClass.includeCfeMessages) {
        shouldGenerateFastaAnalyzerErrorCodes = true;
      }
    }
    out.writeln();
    for (var importPath in imports.toList()..sort()) {
      out.writeln("import ${json.encode(importPath)};");
    }
    out.writeln();
    out.writeln("// It is hard to visually separate each code's _doc comment_ "
        "from its published");
    out.writeln('// _documentation comment_ when each is written as an '
        'end-of-line comment.');
    out.writeln('// ignore_for_file: slash_for_doc_comments');
    if (shouldGenerateFastaAnalyzerErrorCodes) {
      out.writeln();
      _generateFastaAnalyzerErrorCodeList();
    }
    for (var errorClass in errorClasses.toList()
      ..sort((a, b) => a.name.compareTo(b.name))) {
      out.writeln();
      out.write('class ${errorClass.name} extends ${errorClass.superclass} {');
      var entries = [
        ..._analyzerMessages[errorClass.name]!.entries,
        if (errorClass.includeCfeMessages) ...tables.analyzerCodeToInfo.entries
      ];
      for (var entry in entries..sort((a, b) => a.key.compareTo(b.key))) {
        var errorName = entry.key;
        var errorCodeInfo = entry.value;
        out.writeln();
        out.write(errorCodeInfo.toAnalyzerComments(indent: '  '));
        out.writeln('  static const ${errorClass.name} $errorName =');
        out.writeln(errorCodeInfo.toAnalyzerCode(errorClass.name, errorName));
      }
      out.writeln();
      out.writeln('/// Initialize a newly created error code to have the given '
          '[name].');
      out.writeln('const ${errorClass.name}(String name, String message, {');
      out.writeln('String? correction,');
      out.writeln('bool hasPublishedDocs = false,');
      out.writeln('bool isUnresolvedIdentifier = false,');
      out.writeln('String? uniqueName,');
      out.writeln('}) : super(');
      out.writeln('correction: correction,');
      out.writeln('hasPublishedDocs: hasPublishedDocs,');
      out.writeln('isUnresolvedIdentifier: isUnresolvedIdentifier,');
      out.writeln('message: message,');
      out.writeln('name: name,');
      out.writeln("uniqueName: '${errorClass.name}.\${uniqueName ?? name}',");
      out.writeln(');');
      out.writeln();
      out.writeln('@override');
      out.writeln('ErrorSeverity get errorSeverity => '
          '${errorClass.severityCode};');
      out.writeln();
      out.writeln('@override');
      out.writeln('ErrorType get type => ${errorClass.typeCode};');
      out.writeln('}');
    }
  }

  void _generateFastaAnalyzerErrorCodeList() {
    out.writeln('final fastaAnalyzerErrorCodes = <ErrorCode?>[');
    for (var entry in tables.indexToInfo) {
      var name = tables.infoToAnalyzerCode[entry];
      out.writeln('${name == null ? 'null' : 'ParserErrorCode.$name'},');
    }
    out.writeln('];');
  }
}

class _ErrorClassInfo {
  final List<String> extraImports;

  final String filePath;

  final bool includeCfeMessages;

  final String name;

  final String? severity;

  final String superclass;

  final String type;

  const _ErrorClassInfo(
      {this.extraImports = const [],
      required this.filePath,
      this.includeCfeMessages = false,
      required this.name,
      this.severity,
      this.superclass = 'ErrorCode',
      required this.type});

  String get severityCode {
    var severity = this.severity;
    if (severity == null) {
      return '$typeCode.severity';
    } else {
      return 'ErrorSeverity.$severity';
    }
  }

  String get typeCode => 'ErrorType.$type';
}

class _SyntacticErrorGenerator {
  final Map<String, ErrorCodeInfo> cfeMessages;
  final CfeToAnalyzerErrorCodeTables tables;
  final Map<String, Map<String, ErrorCodeInfo>> analyzerMessages;
  final String errorConverterSource;
  final String parserSource;

  factory _SyntacticErrorGenerator() {
    String frontEndPkgPath = normalize(join(pkg_root.packageRoot, 'front_end'));
    String frontEndSharedPkgPath =
        normalize(join(pkg_root.packageRoot, '_fe_analyzer_shared'));

    Map<dynamic, dynamic> cfeMessagesYaml = loadYaml(
        File(join(frontEndPkgPath, 'messages.yaml')).readAsStringSync());
    Map<dynamic, dynamic> analyzerMessagesYaml = loadYaml(
        File(join(analyzerPkgPath, 'messages.yaml')).readAsStringSync());
    String errorConverterSource = File(join(analyzerPkgPath,
            joinAll(posix.split('lib/src/fasta/error_converter.dart'))))
        .readAsStringSync();
    String parserSource = File(join(frontEndSharedPkgPath,
            joinAll(posix.split('lib/src/parser/parser.dart'))))
        .readAsStringSync();

    return _SyntacticErrorGenerator._(
        decodeCfeMessagesYaml(cfeMessagesYaml),
        decodeAnalyzerMessagesYaml(analyzerMessagesYaml),
        errorConverterSource,
        parserSource);
  }

  _SyntacticErrorGenerator._(this.cfeMessages, this.analyzerMessages,
      this.errorConverterSource, this.parserSource)
      : tables = CfeToAnalyzerErrorCodeTables(cfeMessages);

  void checkForManualChanges() {
    // Check for ParserErrorCodes that could be removed from
    // error_converter.dart now that those ParserErrorCodes are auto generated.
    int converterCount = 0;
    for (var errorCode in tables.infoToAnalyzerCode.values) {
      if (errorConverterSource.contains('"$errorCode"')) {
        if (converterCount == 0) {
          print('');
          print('The following ParserErrorCodes could be removed'
              ' from error_converter.dart:');
        }
        print('  $errorCode');
        ++converterCount;
      }
    }
    if (converterCount > 3) {
      print('  $converterCount total');
    }

    // Fail if there are manual changes to be made, but do so
    // in a fire and forget manner so that the files are still generated.
    if (converterCount > 0) {
      print('');
      throw 'Error: missing manual code changes';
    }
  }

  void printSummary() {
    // Build a map of error message to ParserErrorCode
    final messageToName = <String, String>{};
    for (var entry in analyzerMessages['ParserErrorCode']!.entries) {
      String message =
          entry.value.problemMessage.replaceAll(RegExp(r'\{\d+\}'), '');
      messageToName[message] = entry.key;
    }

    String messageFromEntryTemplate(ErrorCodeInfo entry) {
      String problemMessage = entry.problemMessage;
      String message = problemMessage.replaceAll(RegExp(r'#\w+'), '');
      return message;
    }

    // Remove entries that have already been translated
    for (ErrorCodeInfo entry in tables.infoToAnalyzerCode.keys) {
      messageToName.remove(messageFromEntryTemplate(entry));
    }

    // Print the # of autogenerated ParserErrorCodes.
    print('${tables.infoToAnalyzerCode.length} of '
        '${messageToName.length} ParserErrorCodes generated.');

    // List the ParserErrorCodes that could easily be auto generated
    // but have not been already.
    final analyzerToFasta = <String, List<String>>{};
    cfeMessages.forEach((fastaName, entry) {
      final analyzerName = messageToName[messageFromEntryTemplate(entry)];
      if (analyzerName != null) {
        analyzerToFasta
            .putIfAbsent(analyzerName, () => <String>[])
            .add(fastaName);
      }
    });
    if (analyzerToFasta.isNotEmpty) {
      print('');
      print('The following ParserErrorCodes could be auto generated:');
      for (String analyzerName in analyzerToFasta.keys.toList()..sort()) {
        List<String> fastaNames = analyzerToFasta[analyzerName]!;
        if (fastaNames.length == 1) {
          print('  $analyzerName = ${fastaNames.first}');
        } else {
          print('  $analyzerName = $fastaNames');
        }
      }
      if (analyzerToFasta.length > 3) {
        print('  ${analyzerToFasta.length} total');
      }
    }

    // List error codes in the parser that have not been translated.
    final untranslatedFastaErrorCodes = <String>{};
    Token token = scanString(parserSource).tokens;
    while (!token.isEof) {
      if (token.isIdentifier) {
        String? fastaErrorCode;
        String lexeme = token.lexeme;
        if (lexeme.length > 7) {
          if (lexeme.startsWith('message')) {
            fastaErrorCode = lexeme.substring(7);
          } else if (lexeme.length > 8) {
            if (lexeme.startsWith('template')) {
              fastaErrorCode = lexeme.substring(8);
            }
          }
        }
        if (fastaErrorCode != null &&
            tables.frontEndCodeToInfo[fastaErrorCode] == null) {
          untranslatedFastaErrorCodes.add(fastaErrorCode);
        }
      }
      token = token.next!;
    }
    if (untranslatedFastaErrorCodes.isNotEmpty) {
      print('');
      print('The following error codes in the parser are not auto generated:');
      final sorted = untranslatedFastaErrorCodes.toList()..sort();
      for (String fastaErrorCode in sorted) {
        String analyzerCode = '';
        String problemMessage = '';
        var entry = cfeMessages[fastaErrorCode];
        if (entry != null) {
          // TODO(paulberry): handle multiple analyzer codes
          if (entry.index == null && entry.analyzerCode.length == 1) {
            analyzerCode = entry.analyzerCode.single;
            problemMessage = entry.problemMessage;
          }
        }
        print('  ${fastaErrorCode.padRight(30)} --> $analyzerCode'
            '\n      $problemMessage');
      }
    }
  }
}
