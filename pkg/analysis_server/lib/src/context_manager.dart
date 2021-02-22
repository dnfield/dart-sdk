// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:collection';
import 'dart:core';
import 'dart:io';

import 'package:analysis_server/src/plugin/notification_manager.dart';
import 'package:analysis_server/src/services/correction/fix/data_driven/transform_set_parser.dart';
import 'package:analyzer/error/listener.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/instrumentation/instrumentation.dart';
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/performance_logger.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/java_engine.dart';
import 'package:analyzer/src/generated/sdk.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/lint/linter.dart';
import 'package:analyzer/src/lint/pub.dart';
import 'package:analyzer/src/manifest/manifest_validator.dart';
import 'package:analyzer/src/pubspec/pubspec_validator.dart';
import 'package:analyzer/src/task/options.dart';
import 'package:analyzer/src/util/file_paths.dart' as file_paths;
import 'package:analyzer/src/util/glob.dart';
import 'package:analyzer/src/workspace/bazel.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' as protocol;
import 'package:analyzer_plugin/utilities/analyzer_converter.dart';
import 'package:path/path.dart' as pathos;
import 'package:watcher/watcher.dart';
import 'package:yaml/yaml.dart';

/// Enables watching of files generated by Bazel.
///
/// TODO(michalt): This is a temporary flag that we use to disable this
/// functionality due its performance issues. We plan to benchmark and optimize
/// it and re-enable it everywhere.
/// Not private to enable testing.
var experimentalEnableBazelWatching = false;

/// Class that maintains a mapping from included/excluded paths to a set of
/// folders that should correspond to analysis contexts.
abstract class ContextManager {
  // TODO(brianwilkerson) Support:
  //   setting the default analysis options
  //   setting the default content cache
  //   setting the default SDK
  //   telling server when a context has been added or removed
  //       (see onContextsChanged)
  //   telling server when a context needs to be re-analyzed
  //   notifying the client when results should be flushed
  //   using analyzeFileFunctions to determine which files to analyze
  //
  // TODO(brianwilkerson) Move this class to a public library.

  /// Get the callback interface used to create, destroy, and update contexts.
  ContextManagerCallbacks get callbacks;

  /// Set the callback interface used to create, destroy, and update contexts.
  set callbacks(ContextManagerCallbacks value);

  /// A table mapping [Folder]s to the [AnalysisDriver]s associated with them.
  Map<Folder, AnalysisDriver> get driverMap;

  /// Return the list of excluded paths (folders and files) most recently passed
  /// to [setRoots].
  List<String> get excludedPaths;

  /// Return the list of included paths (folders and files) most recently passed
  /// to [setRoots].
  List<String> get includedPaths;

  /// Return the existing analysis context that should be used to analyze the
  /// given [path], or `null` if the [path] is not analyzed in any of the
  /// created analysis contexts.
  DriverBasedAnalysisContext getContextFor(String path);

  /// Return the [AnalysisDriver] for the "innermost" context whose associated
  /// folder is or contains the given path.  ("innermost" refers to the nesting
  /// of contexts, so if there is a context for path /foo and a context for
  /// path /foo/bar, then the innermost context containing /foo/bar/baz.dart is
  /// the context for /foo/bar.)
  ///
  /// If no driver contains the given path, `null` is returned.
  AnalysisDriver getDriverFor(String path);

  /// Determine whether the given [path], when interpreted relative to innermost
  /// context root, contains a folder whose name starts with '.'.
  ///
  /// TODO(scheglov) Remove it, just [isInAnalysisRoot] should be enough.
  bool isContainedInDotFolder(String path);

  /// Return `true` if the given absolute [path] is in one of the current
  /// root folders and is not excluded.
  bool isInAnalysisRoot(String path);

  /// Rebuild the set of contexts from scratch based on the data last sent to
  /// [setRoots].
  void refresh();

  /// Change the set of paths which should be used as starting points to
  /// determine the context directories.
  void setRoots(List<String> includedPaths, List<String> excludedPaths);
}

/// Callback interface used by [ContextManager] to (a) request that contexts be
/// created, destroyed or updated, (b) inform the client when "pub list"
/// operations are in progress, and (c) determine which files should be
/// analyzed.
///
/// TODO(paulberry): eliminate this interface, and instead have [ContextManager]
/// operations return data structures describing how context state should be
/// modified.
abstract class ContextManagerCallbacks {
  /// Return the notification manager associated with the server.
  AbstractNotificationManager get notificationManager;

  /// Called after contexts are rebuilt, such as after recovering from a watcher
  /// failure.
  void afterContextsCreated();

  /// An [event] was processed, so analysis state might be different now.
  void afterWatchEvent(WatchEvent event);

  /// The given [file] was removed.
  void applyFileRemoved(String file);

  /// Sent the given watch [event] to any interested plugins.
  void broadcastWatchEvent(WatchEvent event);

  /// Add listeners to the [driver]. This must be the only listener.
  ///
  /// TODO(scheglov) Just pass results in here?
  void listenAnalysisDriver(AnalysisDriver driver);

  /// Remove the context associated with the given [folder].  [flushedFiles] is
  /// a list of the files which will be "orphaned" by removing this context
  /// (they will no longer be analyzed by any context).
  void removeContext(Folder folder, List<String> flushedFiles);
}

/// Class that maintains a mapping from included/excluded paths to a set of
/// folders that should correspond to analysis contexts.
class ContextManagerImpl implements ContextManager {
  /// The [ResourceProvider] using which paths are converted into [Resource]s.
  final ResourceProvider resourceProvider;

  /// The manager used to access the SDK that should be associated with a
  /// particular context.
  final DartSdkManager sdkManager;

  /// The storage for cached results.
  final ByteStore _byteStore;

  /// The logger used to create analysis contexts.
  final PerformanceLog _performanceLog;

  /// The scheduler used to create analysis contexts, and report status.
  final AnalysisDriverScheduler _scheduler;

  /// The current set of analysis contexts.
  AnalysisContextCollectionImpl _collection;

  /// The context used to work with file system paths.
  pathos.Context pathContext;

  /// The list of excluded paths (folders and files) most recently passed to
  /// [setRoots].
  @override
  List<String> excludedPaths = <String>[];

  /// The list of included paths (folders and files) most recently passed to
  /// [setRoots].
  @override
  List<String> includedPaths = <String>[];

  /// A list of the globs used to determine which files should be analyzed.
  final List<Glob> analyzedFilesGlobs;

  /// The instrumentation service used to report instrumentation data.
  final InstrumentationService _instrumentationService;

  @override
  ContextManagerCallbacks callbacks;

  @override
  final Map<Folder, AnalysisDriver> driverMap =
      HashMap<Folder, AnalysisDriver>();

  /// Stream subscription we are using to watch each analysis root directory for
  /// changes.
  final Map<Folder, StreamSubscription<WatchEvent>> changeSubscriptions =
      <Folder, StreamSubscription<WatchEvent>>{};

  /// For each root directory stores subscriptions and watchers that we
  /// established to detect changes to Bazel generated files.
  final Map<Folder, _BazelWorkspaceSubscription> bazelSubscriptions =
      <Folder, _BazelWorkspaceSubscription>{};

  ContextManagerImpl(
    this.resourceProvider,
    this.sdkManager,
    this._byteStore,
    this._performanceLog,
    this._scheduler,
    this.analyzedFilesGlobs,
    this._instrumentationService,
  ) {
    pathContext = resourceProvider.pathContext;
  }

  @override
  DriverBasedAnalysisContext getContextFor(String path) {
    try {
      return _collection?.contextFor(path);
    } on StateError {
      return null;
    }
  }

  @override
  AnalysisDriver getDriverFor(String path) {
    return getContextFor(path)?.driver;
  }

  /// Determine whether the given [path], when interpreted relative to innermost
  /// context root, contains a folder whose name starts with '.'.
  @override
  bool isContainedInDotFolder(String path) {
    for (var analysisContext in _collection.contexts) {
      var contextImpl = analysisContext as DriverBasedAnalysisContext;
      if (_isContainedInDotFolder(contextImpl.contextRoot.root.path, path)) {
        return true;
      }
    }
    return false;
  }

  @override
  bool isInAnalysisRoot(String path) {
    return _collection.contexts.any(
      (context) => context.contextRoot.isAnalyzed(path),
    );
  }

  @override
  void refresh() {
    _createAnalysisContexts();
  }

  @override
  void setRoots(List<String> includedPaths, List<String> excludedPaths) {
    this.includedPaths = includedPaths;
    this.excludedPaths = excludedPaths;

    _createAnalysisContexts();
  }

  /// Use the given analysis [driver] to analyze the content of the analysis
  /// options file at the given [path].
  void _analyzeAnalysisOptionsFile(AnalysisDriver driver, String path) {
    List<protocol.AnalysisError> convertedErrors;
    try {
      var content = _readFile(path);
      var lineInfo = _computeLineInfo(content);
      var errors = analyzeAnalysisOptions(
          resourceProvider.getFile(path).createSource(),
          content,
          driver.sourceFactory);
      var converter = AnalyzerConverter();
      convertedErrors = converter.convertAnalysisErrors(errors,
          lineInfo: lineInfo, options: driver.analysisOptions);
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.notificationManager.recordAnalysisErrors(
        NotificationManager.serverId,
        path,
        convertedErrors ?? <protocol.AnalysisError>[]);
  }

  /// Use the given analysis [driver] to analyze the content of the
  /// data file at the given [path].
  void _analyzeDataFile(AnalysisDriver driver, String path) {
    List<protocol.AnalysisError> convertedErrors;
    try {
      var file = resourceProvider.getFile(path);
      var packageName = file.parent2.parent2.shortName;
      var content = _readFile(path);
      var errorListener = RecordingErrorListener();
      var errorReporter = ErrorReporter(errorListener, file.createSource());
      var parser = TransformSetParser(errorReporter, packageName);
      parser.parse(content);
      var converter = AnalyzerConverter();
      convertedErrors = converter.convertAnalysisErrors(errorListener.errors,
          lineInfo: _computeLineInfo(content), options: driver.analysisOptions);
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.notificationManager.recordAnalysisErrors(
        NotificationManager.serverId,
        path,
        convertedErrors ?? const <protocol.AnalysisError>[]);
  }

  /// Use the given analysis [driver] to analyze the content of the
  /// AndroidManifest file at the given [path].
  void _analyzeManifestFile(AnalysisDriver driver, String path) {
    List<protocol.AnalysisError> convertedErrors;
    try {
      var content = _readFile(path);
      var validator =
          ManifestValidator(resourceProvider.getFile(path).createSource());
      var lineInfo = _computeLineInfo(content);
      var errors = validator.validate(
          content, driver.analysisOptions.chromeOsManifestChecks);
      var converter = AnalyzerConverter();
      convertedErrors = converter.convertAnalysisErrors(errors,
          lineInfo: lineInfo, options: driver.analysisOptions);
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.notificationManager.recordAnalysisErrors(
        NotificationManager.serverId,
        path,
        convertedErrors ?? <protocol.AnalysisError>[]);
  }

  /// Use the given analysis [driver] to analyze the content of the pubspec file
  /// at the given [path].
  void _analyzePubspecFile(AnalysisDriver driver, String path) {
    List<protocol.AnalysisError> convertedErrors;
    try {
      var content = _readFile(path);
      var node = loadYamlNode(content);
      if (node is YamlMap) {
        var validator = PubspecValidator(
            resourceProvider, resourceProvider.getFile(path).createSource());
        var lineInfo = _computeLineInfo(content);
        var errors = validator.validate(node.nodes);
        var converter = AnalyzerConverter();
        convertedErrors = converter.convertAnalysisErrors(errors,
            lineInfo: lineInfo, options: driver.analysisOptions);

        if (driver.analysisOptions.lint) {
          var visitors = <LintRule, PubspecVisitor>{};
          for (var linter in driver.analysisOptions.lintRules) {
            if (linter is LintRule) {
              var visitor = linter.getPubspecVisitor();
              if (visitor != null) {
                visitors[linter] = visitor;
              }
            }
          }

          if (visitors.isNotEmpty) {
            var sourceUri = resourceProvider.pathContext.toUri(path);
            var pubspecAst = Pubspec.parse(content,
                sourceUrl: sourceUri, resourceProvider: resourceProvider);
            var listener = RecordingErrorListener();
            var reporter = ErrorReporter(listener,
                resourceProvider.getFile(path).createSource(sourceUri),
                isNonNullableByDefault: false);
            for (var entry in visitors.entries) {
              entry.key.reporter = reporter;
              pubspecAst.accept(entry.value);
            }
            if (listener.errors.isNotEmpty) {
              convertedErrors ??= <protocol.AnalysisError>[];
              convertedErrors.addAll(converter.convertAnalysisErrors(
                  listener.errors,
                  lineInfo: lineInfo,
                  options: driver.analysisOptions));
            }
          }
        }
      }
    } catch (exception) {
      // If the file cannot be analyzed, fall through to clear any previous
      // errors.
    }
    callbacks.notificationManager.recordAnalysisErrors(
        NotificationManager.serverId,
        path,
        convertedErrors ?? <protocol.AnalysisError>[]);
  }

  void _checkForDataFileUpdate(String path) {
    if (file_paths.isFixDataYaml(pathContext, path)) {
      var context = getContextFor(path);
      var driver = context.driver;
      _analyzeDataFile(driver, path);
    }
  }

  void _checkForManifestUpdate(String path) {
    if (file_paths.isAndroidManifestXml(pathContext, path)) {
      var context = getContextFor(path);
      var driver = context.driver;
      _analyzeManifestFile(driver, path);
    }
  }

  /// Compute line information for the given [content].
  LineInfo _computeLineInfo(String content) {
    var lineStarts = StringUtilities.computeLineStarts(content);
    return LineInfo(lineStarts);
  }

  void _createAnalysisContexts() {
    if (_collection != null) {
      for (var analysisContext in _collection.contexts) {
        var contextImpl = analysisContext as DriverBasedAnalysisContext;
        _destroyContext(contextImpl);
      }
    }

    _collection = AnalysisContextCollectionImpl(
      includedPaths: includedPaths,
      excludedPaths: excludedPaths,
      byteStore: _byteStore,
      drainStreams: false,
      enableIndex: true,
      performanceLog: _performanceLog,
      resourceProvider: resourceProvider,
      scheduler: _scheduler,
      sdkPath: sdkManager.defaultSdkDirectory,
    );

    for (var context in _collection.contexts) {
      var contextImpl = context as DriverBasedAnalysisContext;
      var driver = contextImpl.driver;

      callbacks.listenAnalysisDriver(driver);

      var rootFolder = contextImpl.contextRoot.root;
      driverMap[rootFolder] = driver;

      changeSubscriptions[rootFolder] = rootFolder.changes
          .listen(_handleWatchEvent, onError: _handleWatchInterruption);

      _watchBazelFilesIfNeeded(rootFolder, driver);

      for (var file in contextImpl.contextRoot.analyzedFiles()) {
        if (_isContainedInDotFolder(contextImpl.contextRoot.root.path, file)) {
          continue;
        }
        driver.addFile(file);
      }

      var optionsFile = context.contextRoot.optionsFile;
      if (optionsFile != null) {
        _analyzeAnalysisOptionsFile(driver, optionsFile.path);
      }

      var dataFile = rootFolder
          .getChildAssumingFolder('lib')
          .getChildAssumingFile(file_paths.fixDataYaml);
      if (dataFile.exists) {
        _analyzeDataFile(driver, dataFile.path);
      }

      var pubspecFile = rootFolder.getChildAssumingFile(file_paths.pubspecYaml);
      if (pubspecFile.exists) {
        _analyzePubspecFile(driver, pubspecFile.path);
      }

      void checkManifestFilesIn(Folder folder) {
        // Don't traverse into dot directories.
        if (folder.shortName.startsWith('.')) {
          return;
        }

        for (var child in folder.getChildren()) {
          if (child is File) {
            if (file_paths.isAndroidManifestXml(pathContext, child.path) &&
                !excludedPaths.contains(child.path)) {
              _analyzeManifestFile(driver, child.path);
            }
          } else if (child is Folder) {
            if (!excludedPaths.contains(child.path)) {
              checkManifestFilesIn(child);
            }
          }
        }
      }

      checkManifestFilesIn(rootFolder);
    }

    callbacks.afterContextsCreated();
  }

  /// Clean up and destroy the context associated with the given folder.
  void _destroyContext(DriverBasedAnalysisContext context) {
    var rootFolder = context.contextRoot.root;
    changeSubscriptions.remove(rootFolder)?.cancel();
    bazelSubscriptions.remove(rootFolder)?.cancel();

    var flushedFiles = context.driver.addedFiles.toList();
    callbacks.removeContext(rootFolder, flushedFiles);
  }

  /// Establishes watch(es) for the Bazel generated files provided in
  /// [notification].
  ///
  /// Whenever the files change, we trigger re-analysis. This allows us to react
  /// to creation/modification of files that were generated by Bazel.
  void _handleBazelFileNotification(
      Folder folder, BazelFileNotification notification) {
    var fileSubscriptions = bazelSubscriptions[folder].fileSubscriptions;
    if (fileSubscriptions.containsKey(notification.requested)) {
      // We have already established a Watcher for this particular path.
      return;
    }
    var watcher = notification.watcher(
        pollingDelayShort: Duration(seconds: 10),
        pollingDelayLong: Duration(seconds: 30));
    var subscription = watcher.events.listen(_handleBazelWatchEvent);
    fileSubscriptions[notification.requested] =
        _BazelFilesSubscription(watcher, subscription);
    watcher.start();
  }

  /// Notifies the drivers that a generated Bazel file has changed.
  void _handleBazelWatchEvent(WatchEvent event) {
    if (event.type == ChangeType.ADD) {
      for (var driver in driverMap.values) {
        driver.addFile(event.path);
        // Since the file has been created after we've searched for it, the
        // URI resolution is likely wrong, so we need to reset it.
        driver.resetUriResolution();
      }
    } else if (event.type == ChangeType.MODIFY) {
      for (var driver in driverMap.values) {
        driver.changeFile(event.path);
      }
    } else if (event.type == ChangeType.REMOVE) {
      for (var driver in driverMap.values) {
        driver.removeFile(event.path);
      }
    }
  }

  void _handleWatchEvent(WatchEvent event) {
    callbacks.broadcastWatchEvent(event);
    _handleWatchEventImpl(event);
    callbacks.afterWatchEvent(event);
  }

  void _handleWatchEventImpl(WatchEvent event) {
    // Figure out which context this event applies to.
    // TODO(brianwilkerson) If a file is explicitly included in one context
    // but implicitly referenced in another context, we will only send a
    // changeSet to the context that explicitly includes the file (because
    // that's the only context that's watching the file).
    var path = event.path;
    var type = event.type;

    _instrumentationService.logWatchEvent('<unknown>', path, type.toString());

    if (file_paths.isAnalysisOptionsYaml(pathContext, path) ||
        file_paths.isDotPackages(pathContext, path) ||
        file_paths.isPackageConfigJson(pathContext, path) ||
        file_paths.isPubspecYaml(pathContext, path) ||
        false) {
      _createAnalysisContexts();
      return;
    }

    if (file_paths.isDart(pathContext, path)) {
      for (var analysisContext_ in _collection.contexts) {
        var analysisContext = analysisContext_ as DriverBasedAnalysisContext;
        switch (type) {
          case ChangeType.ADD:
            // TODO(scheglov) Why not `isInAnalysisRoot()`?
            if (_isContainedInDotFolder(
                analysisContext.contextRoot.root.path, path)) {
              return;
            }
            analysisContext.driver.addFile(path);
            break;
          case ChangeType.MODIFY:
            analysisContext.driver.changeFile(path);
            break;
          case ChangeType.REMOVE:
            analysisContext.driver.removeFile(path);
            // TODO(scheglov) Why not `isInAnalysisRoot()`?
            // TODO(scheglov) Why not always?
            var resource = resourceProvider.getResource(path);
            if (resource is File &&
                _shouldFileBeAnalyzed(resource, mustExist: false)) {
              callbacks.applyFileRemoved(path);
            }
            break;
        }
      }
    }

    _checkForManifestUpdate(path);
    _checkForDataFileUpdate(path);
  }

  /// On windows, the directory watcher may overflow, and we must recover.
  void _handleWatchInterruption(dynamic error, StackTrace stackTrace) {
    // We've handled the error, so we only have to log it.
    AnalysisEngine.instance.instrumentationService
        .logError('Watcher error; refreshing contexts.\n$error\n$stackTrace');
    // TODO(mfairhurst): Optimize this, or perhaps be less complete.
    refresh();
  }

  /// Determine whether the given [path], when interpreted relative to the
  /// context root [root], contains a folder whose name starts with '.' but is
  /// not included in [exclude].
  bool _isContainedInDotFolder(String root, String path,
      {Set<String> exclude}) {
    var pathDir = pathContext.dirname(path);
    var rootPrefix = root + pathContext.separator;
    if (pathDir.startsWith(rootPrefix)) {
      var suffixPath = pathDir.substring(rootPrefix.length);
      for (var pathComponent in pathContext.split(suffixPath)) {
        if (pathComponent.startsWith('.') &&
            !(exclude?.contains(pathComponent) ?? false)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Read the contents of the file at the given [path], or throw an exception
  /// if the contents cannot be read.
  String _readFile(String path) {
    return resourceProvider.getFile(path).readAsStringSync();
  }

  /// Return `true` if the given [file] should be analyzed.
  bool _shouldFileBeAnalyzed(File file, {bool mustExist = true}) {
    for (var glob in analyzedFilesGlobs) {
      if (glob.matches(file.path)) {
        // Emacs creates dummy links to track the fact that a file is open for
        // editing and has unsaved changes (e.g. having unsaved changes to
        // 'foo.dart' causes a link '.#foo.dart' to be created, which points to
        // the non-existent file 'username@hostname.pid'. To avoid these dummy
        // links causing the analyzer to thrash, just ignore links to
        // non-existent files.
        return !mustExist || file.exists;
      }
    }
    return false;
  }

  /// Listens to files generated by Bazel that were found or searched for.
  ///
  /// This is handled specially because the files are outside the package
  /// folder, but we still want to watch for changes to them.
  ///
  /// Does nothing if the [driver] is not in a Bazel workspace.
  void _watchBazelFilesIfNeeded(Folder folder, AnalysisDriver analysisDriver) {
    if (!experimentalEnableBazelWatching) return;
    var workspace = analysisDriver.analysisContext.contextRoot.workspace;
    if (workspace is BazelWorkspace &&
        !bazelSubscriptions.containsKey(folder)) {
      var subscription = workspace.bazelCandidateFiles.listen(
          (notification) => _handleBazelFileNotification(folder, notification));
      bazelSubscriptions[folder] = _BazelWorkspaceSubscription(subscription);
    }
  }

  /// Create and return a source representing the given [file] within the given
  /// [driver].
  static Source createSourceInContext(AnalysisDriver driver, File file) {
    // TODO(brianwilkerson) Optimize this, by allowing support for source
    // factories to restore URI's from a file path rather than a source.
    var source = file.createSource();
    if (driver == null) {
      return source;
    }
    var uri = driver.sourceFactory.restoreUri(source);
    return file.createSource(uri);
  }
}

/// A watcher with subscription used to detect changes to some file.
class _BazelFilesSubscription {
  final BazelFileWatcher watcher;
  final StreamSubscription<WatchEvent> subscription;

  _BazelFilesSubscription(this.watcher, this.subscription);

  void cancel() {
    subscription.cancel();
    watcher.stop();
  }
}

/// A subscription to notifications from a Bazel workspace.
class _BazelWorkspaceSubscription {
  final StreamSubscription<BazelFileNotification> workspaceSubscription;

  /// For each absolute path that we searched for, provides the subscriptions
  /// that we established to watch for changes.
  ///
  /// Note that the absolute path used when searching for a file is not
  /// necessarily the actual path of the file (see [BazelWorkspace.findFile] for
  /// details on how the files are searched).
  final fileSubscriptions = <String, _BazelFilesSubscription>{};

  _BazelWorkspaceSubscription(this.workspaceSubscription);

  void cancel() {
    workspaceSubscription.cancel();
    fileSubscriptions.values.forEach((sub) => sub.cancel());
  }
}
