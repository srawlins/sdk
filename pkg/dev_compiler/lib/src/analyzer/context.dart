// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:args/args.dart' show ArgParser, ArgResults;
import 'package:analyzer/file_system/file_system.dart'
    show ResourceProvider, ResourceUriResolver;
import 'package:analyzer/file_system/physical_file_system.dart'
    show PhysicalResourceProvider;
import 'package:analyzer/source/custom_resolver.dart';
import 'package:analyzer/source/package_map_resolver.dart';
import 'package:analyzer/src/context/builder.dart';
import 'package:analyzer/src/context/context.dart' show AnalysisContextImpl;
import 'package:analyzer/src/dart/sdk/sdk.dart' show FolderBasedDartSdk;
import 'package:analyzer/src/generated/engine.dart'
    show AnalysisEngine, AnalysisOptionsImpl;
import 'package:analyzer/src/generated/source.dart'
    show DartUriResolver, SourceFactory, UriResolver;
import 'package:analyzer/src/summary/package_bundle_reader.dart'
    show InSummaryUriResolver, SummaryDataStore;
import 'package:analyzer/src/summary/summary_sdk.dart' show SummaryBasedDartSdk;
import 'package:cli_util/cli_util.dart' show getSdkDir;
import 'package:path/path.dart' as path;

/// Options used to set up Source URI resolution in the analysis context.
class AnalyzerOptions {
  /// Custom URI mappings, such as "dart:foo" -> "path/to/foo.dart"
  final Map<String, String> customUrlMappings;

  /// Package root when resolving 'package:' urls the standard way.
  final String packageRoot;

  /// List of summary file paths.
  final List<String> summaryPaths;

  /// Path to the dart-sdk. Null if `useMockSdk` is true or if the path couldn't
  /// be determined
  final String dartSdkPath;

  /// Path to the dart-sdk summary.  If this is set, it will be used in favor
  /// of the unsummarized one.
  final String dartSdkSummaryPath;

  /// Defined variables used by `bool.fromEnvironment` etc.
  final Map<String, String> declaredVariables;

  AnalyzerOptions(
      {this.summaryPaths: const [],
      String dartSdkPath,
      this.dartSdkSummaryPath,
      this.customUrlMappings: const {},
      this.packageRoot: null,
      this.declaredVariables: const {}})
      : dartSdkPath = dartSdkPath ?? getSdkDir().path;

  factory AnalyzerOptions.fromArguments(
      ArgResults args, Map<String, String> declaredVariables) {
    var sdkPath = args['dart-sdk'] ?? getSdkDir().path;
    var sdkSummaryPath = args['dart-sdk-summary'];

    if (sdkSummaryPath == null) {
      sdkSummaryPath = path.join(sdkPath, 'lib', '_internal', 'ddc_sdk.sum');
    } else if (sdkSummaryPath == 'build') {
      // For building the SDK, we explicitly set the path to none.
      sdkSummaryPath = null;
    }

    return new AnalyzerOptions(
        summaryPaths: args['summary'] as List<String>,
        dartSdkPath: sdkPath,
        dartSdkSummaryPath: sdkSummaryPath,
        customUrlMappings: _parseUrlMappings(args['url-mapping']),
        packageRoot: args['package-root'],
        declaredVariables: declaredVariables);
  }

  static void addArguments(ArgParser parser, {bool hide: true}) {
    parser
      ..addOption('summary',
          abbr: 's', help: 'summary file(s) to include', allowMultiple: true)
      ..addOption('dart-sdk',
          help: 'Dart SDK Path', defaultsTo: null, hide: hide)
      ..addOption('dart-sdk-summary',
          help: 'Dart SDK Summary Path', defaultsTo: null, hide: hide)
      ..addOption('package-root',
          abbr: 'p', help: 'Package root to resolve "package:" imports')
      ..addOption('url-mapping',
          help: '--url-mapping=libraryUri,/path/to/library.dart uses\n'
              'library.dart as the source for an import of of "libraryUri".',
          allowMultiple: true,
          splitCommas: false);
  }

  static Map<String, String> _parseUrlMappings(Iterable argument) {
    var mappings = <String, String>{};
    for (var mapping in argument) {
      var splitMapping = mapping.split(',');
      if (splitMapping.length >= 2) {
        mappings[splitMapping[0]] = path.absolute(splitMapping[1]);
      }
    }
    return mappings;
  }
}

/// Creates an analysis context that contains our restricted typing rules.
AnalysisContextImpl createAnalysisContext() {
  var res = AnalysisEngine.instance.createAnalysisContext();
  res.analysisOptions = new AnalysisOptionsImpl()
    ..strongMode = true
    ..trackCacheDependencies = false;
  return res;
}

/// Creates a SourceFactory configured by the [options].
///
/// Use [options.useMockSdk] to specify the SDK mode, or use [sdkResolver]
/// to entirely override the DartUriResolver.
///
/// If supplied, [fileResolvers] will override the default `file:` and
/// `package:` URI resolvers.
SourceFactory createSourceFactory(AnalyzerOptions options,
    {DartUriResolver sdkResolver,
    List<UriResolver> fileResolvers,
    SummaryDataStore summaryData,
    ResourceProvider resourceProvider}) {
  resourceProvider ??= PhysicalResourceProvider.INSTANCE;
  var resolvers = <UriResolver>[];
  if (options.customUrlMappings.isNotEmpty) {
    resolvers.add(
        new CustomUriResolver(resourceProvider, options.customUrlMappings));
  }
  resolvers.add(sdkResolver);
  if (summaryData != null) {
    resolvers.add(new InSummaryUriResolver(resourceProvider, summaryData));
  }

  if (fileResolvers == null)
    fileResolvers =
        createFileResolvers(options, resourceProvider: resourceProvider);
  resolvers.addAll(fileResolvers);
  return new SourceFactory(resolvers, null, resourceProvider);
}

List<UriResolver> createFileResolvers(AnalyzerOptions options,
    {ResourceProvider resourceProvider}) {
  resourceProvider ??= PhysicalResourceProvider.INSTANCE;
  UriResolver packageResolver() {
    ContextBuilderOptions builderOptions = new ContextBuilderOptions();
    if (options.packageRoot != null) {
      builderOptions.defaultPackagesDirectoryPath = options.packageRoot;
    }
    ContextBuilder builder = new ContextBuilder(resourceProvider, null, null,
        options: builderOptions);
    return new PackageMapUriResolver(resourceProvider,
        builder.convertPackagesToMap(builder.createPackageMap('')));
  }

  return [new ResourceUriResolver(resourceProvider), packageResolver()];
}

FolderBasedDartSdk _createFolderBasedDartSdk(String sdkPath) {
  var resourceProvider = PhysicalResourceProvider.INSTANCE;
  var sdk = new FolderBasedDartSdk(resourceProvider,
      resourceProvider.getFolder(sdkPath), /*useDart2jsPaths:*/ true);
  sdk.useSummary = true;
  sdk.analysisOptions = new AnalysisOptionsImpl()..strongMode = true;
  return sdk;
}

/// Creates a [DartUriResolver] that uses the SDK at the given [sdkPath].
DartUriResolver createSdkPathResolver(String sdkSummaryPath, String sdkPath) {
  var sdk = (sdkSummaryPath != null)
      ? new SummaryBasedDartSdk(sdkSummaryPath, true)
      : _createFolderBasedDartSdk(sdkPath);
  return new DartUriResolver(sdk);
}

List<String> parseDeclaredVariables(
    List<String> args, Map<String, String> declaredVars) {
  var count = args.length;
  var remainingArgs = <String>[];
  for (int i = 0; i < count; i++) {
    var arg = args[i];
    if (arg == '--') {
      while (i < count) {
        remainingArgs.add(args[i++]);
      }
    } else if (arg.startsWith("-D")) {
      // The format for defined variables is:
      //     -D<name>=<value>
      var parts = arg.substring(2).split('=');
      declaredVars[parts[0]] = parts.length > 1 ? parts[1] : '';
    } else {
      remainingArgs.add(arg);
    }
  }
  return remainingArgs;
}
