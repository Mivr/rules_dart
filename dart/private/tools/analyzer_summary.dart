// Build-action runner for the analyzer-summary mode of the `dart_analyze`
// aspect, which `//dart:analyzer_summaries` selects (on by default).
//
// `summarize` writes one package's summary: `package:analyzer`'s bundle of the
// libraries its own sources declare, linked against the summaries of its
// dependencies. `analyze` checks a staged project's own files against those
// summaries, instead of against every dependency's source, and prints each
// diagnostic in `dart analyze`'s format. Both run the pinned `package:analyzer`
// rather than the SDK's copy, so the lint rules come from the vendored linter
// under //third_party/dart_linter, which is the SDK's own set.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/analysis_options.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/sdk/build_sdk_summary.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/source/error_processor.dart';
import 'package:analyzer/source/line_info.dart';
// ignore: implementation_imports
import 'package:analyzer/src/analysis_options/options_file_validator.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver.dart';
// ignore: implementation_imports
import 'package:linter/src/rules.dart';
import 'package:path/path.dart' as p;

const _optionsBasename = 'analysis_options.yaml';
const _packageConfig = '.dart_tool/package_config.json';

/// `EX_USAGE`: a bad command line.
const _usage = 64;

/// A check that found problems, or a file that could not be analyzed.
const _failed = 1;

Future<void> main(List<String> args) async {
  // The lint rules `dart analyze` runs, registered once, before any analysis
  // context reads `linter:` from an options file.
  registerLintRules();
  if (args.isEmpty) {
    exit(_usageError('a mode is required: `summarize` or `analyze`'));
  }
  final parsed = _Args.parse(args.sublist(1));
  final code = switch (args.first) {
    'sdk' => await _sdk(parsed),
    'summarize' => await _summarize(parsed),
    'analyze' => await _analyze(parsed),
    _ => _usageError('unknown mode `${args.first}`'),
  };
  exit(code);
}

int _usageError(String message) {
  stderr.writeln('analyzer_summary: $message');
  return _usage;
}

/// Writes the summary of the SDK's own libraries.
///
/// A dependency's summary refers to the SDK libraries it imports, such as
/// `dart:io`, and those are not in any package's summary. Analysis reads them
/// from this one, which every `summarize` and `analyze` also takes. When
/// `--embedder-yaml` is given, the embedder's libraries (Flutter's `dart:ui`,
/// from `sky_engine`'s `lib/_embedder.yaml`) are built into the summary as
/// well.
Future<int> _sdk(_Args args) async {
  final embedder = args.all('embedder-yaml');
  final bytes = await buildSdkSummary(
    resourceProvider: PhysicalResourceProvider.INSTANCE,
    sdkPath: p.absolute(args.single('sdk')),
    embedderYamlPath: embedder.isEmpty ? null : p.absolute(embedder.single),
  );
  File(args.single('out')).writeAsBytesSync(bytes);
  return 0;
}

/// Writes the summary of one package's libraries.
///
/// `--source` and `--uri` pair up in order: the i-th source is the library at
/// the i-th `package:` URI. A `part` file is staged with the others, so its
/// library resolves it, but it is not a library and has no URI in the bundle:
/// naming it as one fails the bundle with "Missing library".
Future<int> _summarize(_Args args) async {
  final sources = args.all('source');
  final uris = args.all('uri');
  if (sources.isEmpty || sources.length != uris.length) {
    return _usageError(
      'summarize needs a --source for each --uri, and at least one of each',
    );
  }
  final libraryUris = <String>[
    for (var i = 0; i < sources.length; i++)
      if (!_isPart(sources[i])) uris[i],
  ];
  final collection = AnalysisContextCollectionImpl(
    includedPaths: [for (final s in sources) p.absolute(s)],
    sdkPath: p.absolute(args.single('sdk')),
    sdkSummaryPath: p.absolute(args.single('sdk-summary')),
    packageConfigFile: p.absolute(args.single('packages')),
    librarySummaryPaths: [for (final s in args.all('summary')) p.absolute(s)],
  );
  final driver = collection.contexts.single.driver;
  final bytes = await driver.buildPackageBundle(
    uriList: [for (final u in libraryUris) Uri.parse(u)],
  );
  // The collection is not disposed. On analyzer 13.3.0, `dispose` after a
  // summary build threw "Expected to link dart:core and dart:async first". On
  // 14.1.0 it does not, in the summary-then-consumer shape this action runs, but
  // the process exits straight after, so there is nothing to release.
  File(args.single('out')).writeAsBytesSync(bytes);
  return 0;
}

/// Whether the Dart file at [path] is a `part` of a library, rather than one.
bool _isPart(String path) {
  final unit = parseString(
    content: File(path).readAsStringSync(),
    path: path,
    throwIfDiagnostics: false,
  ).unit;
  return unit.directives.any((d) => d is PartOfDirective);
}

/// Checks a staged project's own files, and writes the stamp if they pass.
Future<int> _analyze(_Args args) async {
  final project = p.absolute(args.single('project'));
  final stamp = args.single('stamp');
  final fatalInfos = args.flag('fatal-infos');
  final collection = AnalysisContextCollectionImpl(
    includedPaths: [project],
    sdkPath: p.absolute(args.single('sdk')),
    sdkSummaryPath: p.absolute(args.single('sdk-summary')),
    packageConfigFile: p.join(project, _packageConfig),
    librarySummaryPaths: [for (final s in args.all('summary')) p.absolute(s)],
  );
  final context = collection.contexts.single;
  final driver = context.driver;

  final findings = <_Finding>[];
  for (final path in _analyzedPaths(project, context)) {
    final options = context.getAnalysisOptionsForFile(
      PhysicalResourceProvider.INSTANCE.getFile(path),
    );
    if (p.basename(path) == _optionsBasename) {
      findings.addAll(_optionsFindings(project, driver, path, options));
      continue;
    }
    final result = await driver.getErrors(path);
    if (result is! ErrorsResult) {
      stderr.writeln('analyzer_summary: cannot analyze $path');
      return _failed;
    }
    for (final d in result.diagnostics) {
      findings.add(_finding(project, path, result.lineInfo, options, d));
    }
  }

  // Printed as `dart analyze` prints them: most severe first, then by file
  // and position.
  findings.sort();
  final shown = [
    for (final f in findings)
      if (f.level != null) f,
  ];
  if (shown.isNotEmpty) {
    stdout.writeln();
    for (final f in shown) {
      stdout.writeln(f.text);
    }
    stdout.writeln();
    stdout.writeln(
      shown.length == 1 ? '1 issue found.' : '${shown.length} issues found.',
    );
  }

  final failing =
      shown.any(
        (f) => f.level == Severity.error || f.level == Severity.warning,
      ) ||
      (fatalInfos && shown.any((f) => f.level == Severity.info));
  if (failing) {
    return _failed;
  }
  File(stamp).writeAsStringSync('analyzed\n');
  return 0;
}

/// Every Dart file and options file under the project that the analyzer
/// analyzes, sorted. The staged tree's excludes apply, as they do to
/// `dart analyze`.
List<String> _analyzedPaths(String project, AnalysisContext context) {
  final paths = <String>[];
  for (final entity in Directory(project).listSync(recursive: true)) {
    // Follows links, so a staged file that is a symlink is still a file.
    final path = p.normalize(entity.absolute.path);
    if (!FileSystemEntity.isFileSync(path)) continue;
    if (p.split(path).contains('.dart_tool')) continue;
    final name = p.basename(path);
    if (!name.endsWith('.dart') && name != _optionsBasename) continue;
    if (!context.contextRoot.isAnalyzed(path)) continue;
    paths.add(path);
  }
  paths.sort();
  return paths;
}

/// The diagnostics of one options file: the `include:` and lint-name checks
/// the analysis server runs on it, which the driver does not.
List<_Finding> _optionsFindings(
  String project,
  AnalysisDriver driver,
  String path,
  AnalysisOptions options,
) {
  final content = File(path).readAsStringSync();
  final source = driver.sourceFactory.forUri2(Uri.file(path));
  if (source == null) return const [];
  final validator = AnalysisOptionsAnalyzer(
    initialSource: source,
    sourceFactory: driver.sourceFactory,
    contextRoot: project,
    sdkVersionConstraint: null,
    resourceProvider: PhysicalResourceProvider.INSTANCE,
  );
  final lines = LineInfo.fromContent(content);
  return [
    for (final d in validator.walkIncludes(content: content))
      _finding(project, path, lines, options, d),
  ];
}

/// One diagnostic as it is printed, at its severity after `analyzer: errors:`.
///
/// The driver reports each diagnostic at its code's own severity and does not
/// apply error processors, so the overrides are applied here. A diagnostic an
/// override sets to `ignore` gets a null level and is not printed. The driver
/// already drops diagnostics suppressed by `// ignore:`.
_Finding _finding(
  String project,
  String path,
  LineInfo lines,
  AnalysisOptions options,
  Diagnostic d,
) {
  final processor = ErrorProcessor.getProcessor(options, d);
  final level = processor == null
      ? d.severity
      : switch (processor.severity) {
          DiagnosticSeverity.ERROR => Severity.error,
          DiagnosticSeverity.WARNING => Severity.warning,
          DiagnosticSeverity.INFO => Severity.info,
          _ => null,
        };
  final location = lines.getLocation(d.offset);
  final where = _display(project, path);
  final message = StringBuffer(
    _unstage(d.problemMessage.messageText(includeUrl: false), project),
  );
  if (d.correctionMessage case final correction?) {
    message
      ..write(' ')
      ..write(_unstage(correction, project));
  }
  // `dart analyze` right-aligns the severity in the width of `warning`, so
  // `error` and `info` are indented.
  final text =
      '${(level?.name ?? '').padLeft(7)} - $where:${location.lineNumber}:'
      '${location.columnNumber} - $message - ${d.diagnosticCode.lowerCaseName}';
  return _Finding(
    level: level,
    path: where,
    line: location.lineNumber,
    column: location.columnNumber,
    text: text,
  );
}

/// The workspace path of a staged file: its path under `src/`, where the
/// workspace's own files sit at their workspace-relative paths.
String _display(String project, String path) {
  final relative = p.relative(path, from: project).replaceAll(r'\', '/');
  return relative.startsWith('src/') ? relative.substring(4) : relative;
}

/// Rewrites staged paths in a message to the workspace paths they were copied
/// from. Some messages quote an absolute path (an unresolvable `include:` names
/// the options file that holds it), so both forms are rewritten.
String _unstage(String text, String project) {
  final absolute = p.absolute(project).replaceAll(r'\', '/');
  return text
      .replaceAll('$absolute/src/', '')
      .replaceAll('$absolute/src', '.')
      .replaceAll(absolute, '.')
      .replaceAll(r'\', '/');
}

/// A diagnostic ready to print, ordered most severe first.
final class _Finding implements Comparable<_Finding> {
  const _Finding({
    required this.level,
    required this.path,
    required this.line,
    required this.column,
    required this.text,
  });

  /// The severity after overrides; null when an override ignores it.
  final Severity? level;
  final String path;
  final int line;
  final int column;

  /// The line as printed.
  final String text;

  @override
  int compareTo(_Finding other) {
    final byLevel = _rank(level).compareTo(_rank(other.level));
    if (byLevel != 0) return byLevel;
    final byPath = path.compareTo(other.path);
    if (byPath != 0) return byPath;
    final byLine = line.compareTo(other.line);
    if (byLine != 0) return byLine;
    return column.compareTo(other.column);
  }

  static int _rank(Severity? level) => switch (level) {
    Severity.error => 0,
    Severity.warning => 1,
    Severity.info => 2,
    null => 3,
  };
}

/// Parsed command-line arguments: repeatable `--name value` pairs, and bare
/// `--flag`s.
final class _Args {
  _Args._(this._values, this._flags);

  factory _Args.parse(List<String> args) {
    final values = <String, List<String>>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) {
        stderr.writeln('analyzer_summary: unexpected argument `$arg`');
        exit(_usage);
      }
      final name = arg.substring(2);
      if (name == 'fatal-infos') {
        flags.add(name);
        continue;
      }
      if (i + 1 >= args.length) {
        stderr.writeln('analyzer_summary: `$arg` needs a value');
        exit(_usage);
      }
      values.putIfAbsent(name, () => []).add(args[++i]);
    }
    return _Args._(values, flags);
  }

  final Map<String, List<String>> _values;
  final Set<String> _flags;

  bool flag(String name) => _flags.contains(name);

  List<String> all(String name) => _values[name] ?? const [];

  String single(String name) {
    final values = all(name);
    if (values.length != 1) {
      stderr.writeln('analyzer_summary: `--$name` is required exactly once');
      exit(_usage);
    }
    return values.single;
  }
}
