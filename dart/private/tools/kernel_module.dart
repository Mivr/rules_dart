// Compiles one kernel module with `kernel_worker`. See `kernel_module_action` in
// `dart/private/dart_kernel.bzl`.
//
// A module compiles the sources its `dart_library` declares, except the files that
// cannot compile for the VM. Which files those are is decided before compiling,
// from the import graph, by reading each source's directives:
//
//  * A file that imports or exports a `dart:` library the VM does not have
//    (`dart:html`, `dart:js_interop`, ...) is excluded.
//  * A file that imports or exports a `package:` URI whose package is not in the
//    module's package config is excluded, since the module cannot resolve it.
//  * A file with a `part` directive whose part is not one of the module's
//    inputs, or a `part of` file whose library is not one of the module's
//    inputs, is excluded, since a library and its parts cannot compile apart.
//  * A file that imports or exports an excluded file is excluded. A `part` shares
//    its library's verdict.
//  * A conditional import takes its first `dart.library.X` alternative for a VM
//    library X, and its default URI otherwise.
//  * The VM libraries are those of the `vm` platform in the SDK's `libraries.json`,
//    following its `include`s.
//  * A source that a dependency module already defines is not compiled again. The
//    kernels the module links against define it, and the module's dependents link
//    to that kernel.
//  * An excluded file is listed in the module's `.vm_excluded.txt` sidecar. A
//    dependent module reads the sidecars of its whole closure, so the files that
//    import an excluded file are excluded too. A dependent that lists the excluded
//    file among its own sources compiles its own copy, if it can. An excluded file
//    that some module of the closure defines is not excluded for the closure at all.
//
// The module's output is a directory. It holds one kernel per strongly connected
// component of its own sources (libraries that import each other compile together,
// and a part belongs to its library), and an `index.json` that lists them: each
// kernel's file, the keys of the libraries it defines, and the keys it imports. A
// component compiles against only the kernels it reaches, passed as `--input-summary`,
// and a kernel is written after every kernel it imports.
//
// When `--output-outline` is given, each compiled component is also stripped to a
// deterministic outline `.dill` (`stripDillToOutline`) in the `.koutline` directory
// for downstream `--input-summary` compiles, while the `.kmod` directory keeps the
// full component with embedded source text stripped (`stripSourceCodeFromDill`). Any
// class that can be used as a mixin (`mixin`, `mixin class`, and every class in a
// library whose language version is below 3.0) keeps its member bodies and field
// initializers in `.koutline`. Both strippers check the 32-bit kernel format version
// in the header (accepting version 138, Dart 3.13.x) and log a diagnostic to `stderr`
// while falling back to the unstripped `.dill` bytes on any other version.
//
// A dependent module names its dependencies' directories with `--input-kmod`. It reads
// their indexes, and each component compiles against the kernels it reaches through
// them.
//
// The remaining sources compile with `--exclude-non-sources`, so a kernel holds its
// own libraries and nothing it links against. An error from one of them is real, and
// fails the action with the compiler's output. The one exception is a safety net: an
// error that can be blamed on an own source drops that source and its importers, and
// the module compiles once more. Any other error fails at once.
//
// An executable's entry module compiles from source every file it reaches that the
// closure excludes and no module defines, so the compiler reports the genuine VM error
// exactly as a whole-program compile would. It has no safety net. Its kernel is linked,
// with the kernels it reaches, by `kernel_link`.
//
// With `--persistent_worker` this is a Bazel persistent worker. It keeps one
// `kernel_worker` child running for its requests, retries included. When the child
// cannot be trusted, the child is killed, a new one starts, and the request is sent to
// it once more. That is after the child dies, after a request runs past the timeout
// (15 minutes, or `--request-timeout-seconds=N` for a test), after bytes that are not
// the answer to the request, and after a crash, since a crashed child never answers its
// next request. A second failure fails the action, with both attempts' output. Without
// the flag it runs one compile. Either way it prints nothing on success, and on a
// failure it prints the full diagnostics.
//
// The worker protocol is spoken directly, as a length-prefixed `WorkRequest` and
// `WorkResponse`, rather than through `package:bazel_worker`. That package is a
// `dart_library`, and every `dart_library` carries this tool as an attribute, so
// depending on it would make a cycle.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'dill_outline.dart';

const _kernelWorkerFlag = '--kernel-worker';
const _dartaotruntimeFlag = '--dartaotruntime';
const _persistentFlag = '--persistent_worker';

// Flags this tool consumes. `kernel_worker` never sees them.
const _excludedOutputFlag = '--excluded-output';
const _closureExcludedFlag = '--closure-excluded';
const _librariesJsonFlag = '--libraries-json';
const _librariesPlatformFlag = '--libraries-platform';
const _extraLibraryFlag = '--extra-library';
const _inputKmodFlag = '--input-kmod';
const _inputSourceFlag = '--input-source';
const _outputOutlineFlag = '--output-outline';

/// The file in each module directory that lists its kernels.
const _indexName = 'index.json';
const _noDropFlag = '--no-drop';
const _packagesFlag = '--packages-file';
const _multiRootFlag = '--multi-root';
const _multiRootSchemeFlag = '--multi-root-scheme';

const _defaultMultiRootPrefix = 'org-dartlang-root:///';

/// `<path>:<line>:<col>: Error: <message>`, one per located diagnostic.
final _errorLine = RegExp(r'^(.+?):(\d+):(\d+): Error: (.*)$', multiLine: true);

/// The `bazel-out/<config>/bin/` prefix a diagnostic may give a generated file.
final _bazelOutPrefix = RegExp(r'^(?:\./)?bazel-out/[^/]+/bin/');

const _kernelWorkerUriFlags = <String>{
  '--dart-sdk-summary',
  '--packages-file',
  '--libraries-file',
  '--multi-root',
  '--input-summary',
  '--input-linked',
  '--source',
  '--native-assets',
};

bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);

/// True when [s] starts with a Windows drive letter (`C:/...`, `d:\...`, `C:`).
bool isWindowsDrivePath(String s) =>
    s.length >= 2 &&
    _isAsciiAlpha(s.codeUnitAt(0)) &&
    s.codeUnitAt(1) == 0x3a &&
    (s.length == 2 || s.codeUnitAt(2) == 0x2f || s.codeUnitAt(2) == 0x5c);

/// Converts a Windows drive-letter or UNC file path to a `file://` URI string
/// for `kernel_worker` (`package:frontend_server/compute_kernel.dart`).
///
/// `kernel_worker` resolves URI-bearing flags via
/// `Uri.base.resolve(s.replaceAll(r'\', '/'))`. For an absolute Windows path
/// such as `d:/_bazel/...` or `C:\Users\...`, `Uri.base.resolve` treats the
/// drive letter as a URI scheme (`scheme: 'd'`), which `StandardFileSystem`
/// rejects (`StandardFileSystem only supports file:* and data:* URIs`).
String kernelWorkerUri(String pathOrUri) {
  if (isWindowsDrivePath(pathOrUri) || pathOrUri.startsWith(r'\\')) {
    return Uri.file(pathOrUri, windows: true).toString();
  }
  return pathOrUri;
}

String _filePathOf(String pathOrUri) {
  if (pathOrUri.startsWith('file:///')) {
    final rest = pathOrUri.substring('file:///'.length);
    if (isWindowsDrivePath(rest)) return rest;
  }
  if (pathOrUri.startsWith('file://')) {
    return Uri.parse(pathOrUri).toFilePath(windows: true);
  }
  return pathOrUri;
}

String _rewriteRedirectUri(String value) {
  final sep = value.indexOf('|');
  if (sep < 0) return kernelWorkerUri(value);
  return '${kernelWorkerUri(value.substring(0, sep))}|'
      '${kernelWorkerUri(value.substring(sep + 1))}';
}

/// Rewrites Windows drive-letter and UNC paths in `kernel_worker` URI-bearing
/// flags to `file:///` URIs while leaving `--output` and other file-system
/// path flags unchanged.
List<String> kernelWorkerArgs(List<String> args) {
  final out = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (_kernelWorkerUriFlags.contains(arg) && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(kernelWorkerUri(args[++i]));
      continue;
    }
    if (arg == '--redirect' && i + 1 < args.length) {
      out
        ..add(arg)
        ..add(_rewriteRedirectUri(args[++i]));
      continue;
    }
    if (arg.startsWith('--redirect=')) {
      final raw = arg.substring('--redirect='.length);
      out.add('--redirect=${_rewriteRedirectUri(raw)}');
      continue;
    }
    var matchedEq = false;
    for (final flag in _kernelWorkerUriFlags) {
      final prefix = '$flag=';
      if (arg.startsWith(prefix)) {
        out.add('$flag=${kernelWorkerUri(arg.substring(prefix.length))}');
        matchedEq = true;
        break;
      }
    }
    if (!matchedEq) {
      out.add(arg);
    }
  }
  return out;
}

Future<void> main(List<String> argv) async {
  var persistent = false;
  String? kernelWorker;
  String? dartaotruntime;
  Duration? requestTimeout;
  final rest = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == _persistentFlag) {
      persistent = true;
    } else if (arg.startsWith(_requestTimeoutFlag)) {
      final seconds = int.tryParse(arg.substring(_requestTimeoutFlag.length));
      if (seconds == null || seconds <= 0) {
        stderr.writeln(
          'kernel_module: $arg is not a positive number of seconds.',
        );
        exitCode = 64;
        return;
      }
      requestTimeout = Duration(seconds: seconds);
    } else if (arg == _kernelWorkerFlag) {
      kernelWorker = argv[++i];
    } else if (arg == _dartaotruntimeFlag) {
      dartaotruntime = argv[++i];
    } else {
      rest.add(arg);
    }
  }
  if (kernelWorker == null || dartaotruntime == null) {
    stderr.writeln(
      'kernel_module: $_kernelWorkerFlag and $_dartaotruntimeFlag are required.',
    );
    exitCode = 64;
    return;
  }
  if (persistent) {
    await _serve(dartaotruntime, kernelWorker, requestTimeout);
    // Exit explicitly. Streams of the `kernel_worker` child stay subscribed after
    // it is killed, and would otherwise keep this process alive past its work.
    await stdout.flush();
    exit(0);
  }
  final args = await _expandParamFiles(rest);
  final log = StringBuffer();
  final code = await compileModule(
    args,
    _OneShot(dartaotruntime, kernelWorker),
    log,
    const [],
  );
  if (code != 0) {
    stderr.write(log);
  }
  await stderr.flush();
  exit(code);
}

/// Serves Bazel `WorkRequest`s until stdin closes.
Future<void> _serve(
  String dartaotruntime,
  String kernelWorker,
  Duration? requestTimeout,
) async {
  final requests = _Frames(stdin);
  final cache = KernelModuleCache();
  final compiler = _Persistent(
    dartaotruntime,
    kernelWorker,
    requestTimeout: requestTimeout,
  );
  try {
    while (true) {
      final frame = await requests.next();
      if (frame == null) break;
      // Every request is answered, even one that fails to decode or compile:
      // a worker that closes stdout without a `WorkResponse` fails the action
      // with no diagnostics at all.
      final log = StringBuffer();
      var code = 1;
      var requestId = 0;
      try {
        final request = _WorkRequest.decode(frame);
        requestId = request.requestId;
        code = await compileModule(
          request.arguments,
          compiler,
          log,
          request.inputs,
          cache: cache,
        );
      } catch (error, stack) {
        log.writeln('kernel_module: $error\n$stack');
      }
      stdout.add(_frame(_encodeResponse(code, log.toString(), requestId)));
      await stdout.flush();
    }
  } finally {
    await compiler.close();
  }
}

/// Compiles one module, or the entry module when `--no-drop` is set.
///
/// The module's directory receives one kernel per strongly connected component of its
/// own sources, and an `index.json` that lists them. Returns 0 on success. Returns 1
/// when a compile fails, with the compiler's output in `log`. Returns 64 when an
/// argument is missing.
///
/// Public so that a test can drive the planner with a [ModuleCompiler] that records its
/// arguments, without a `kernel_worker`.
Future<int> compileModule(
  List<String> rawArgs,
  ModuleCompiler compiler,
  StringBuffer log,
  List<Uint8List> inputs, {
  KernelModuleCache? cache,
}) async {
  final base = <String>[];
  final sources = <String>[];
  final inputSources = <String>[];
  final multiRoots = <String>[];
  final closureExcluded = <String>[];
  final inputKmods = <String>[];
  final extraLibraries = <String>[];
  String? excludedPath;
  String? output;
  String? outputOutline;
  String? packagesFile;
  String? librariesJson;
  var librariesPlatform = 'vm';
  var multiRootPrefix = _defaultMultiRootPrefix;
  var noDrop = false;
  for (var i = 0; i < rawArgs.length; i++) {
    final arg = rawArgs[i];
    if (arg == '--source') {
      sources.add(rawArgs[++i]);
    } else if (arg == _inputSourceFlag) {
      inputSources.add(rawArgs[++i]);
    } else if (arg == '--output') {
      output = rawArgs[++i];
    } else if (arg == _outputOutlineFlag) {
      outputOutline = rawArgs[++i];
    } else if (arg == _excludedOutputFlag) {
      excludedPath = rawArgs[++i];
    } else if (arg == _closureExcludedFlag) {
      closureExcluded.add(rawArgs[++i]);
    } else if (arg == _inputKmodFlag) {
      inputKmods.add(rawArgs[++i]);
    } else if (arg == _librariesJsonFlag) {
      librariesJson = rawArgs[++i];
    } else if (arg == _librariesPlatformFlag) {
      librariesPlatform = rawArgs[++i];
    } else if (arg == _extraLibraryFlag) {
      extraLibraries.add(rawArgs[++i]);
    } else if (arg == _noDropFlag) {
      noDrop = true;
    } else if (arg == '--input-linked') {
      log.writeln(
        'kernel_module: --input-linked is not accepted; pass $_inputKmodFlag.',
      );
      return 64;
    } else if ((arg == '-D' || arg == '--define') && i + 1 < rawArgs.length) {
      base
        ..add(arg)
        ..add(rawArgs[++i]);
    } else {
      if (arg == _packagesFlag) {
        packagesFile = rawArgs[i + 1];
      } else if (arg.startsWith('$_packagesFlag=')) {
        packagesFile = arg.substring(_packagesFlag.length + 1);
      } else if (arg == _multiRootFlag) {
        multiRoots.add(rawArgs[i + 1]);
      } else if (arg.startsWith('$_multiRootFlag=')) {
        multiRoots.add(arg.substring(_multiRootFlag.length + 1));
      } else if (arg == _multiRootSchemeFlag) {
        multiRootPrefix = '${rawArgs[i + 1]}:///';
      } else if (arg.startsWith('$_multiRootSchemeFlag=')) {
        multiRootPrefix =
            '${arg.substring(_multiRootSchemeFlag.length + 1)}:///';
      }
      base.add(arg);
    }
  }
  if (excludedPath == null ||
      output == null ||
      packagesFile == null ||
      librariesJson == null) {
    log.writeln(
      'kernel_module: $_excludedOutputFlag, $_librariesJsonFlag, --output and '
      '$_packagesFlag are required.',
    );
    return 64;
  }

  final Set<String>? workerInputPaths;
  final Map<String, Uint8List>? inputDigests;
  final exactInputPathsWithDigest = <String>{};
  if (inputs.isEmpty) {
    workerInputPaths = null;
    inputDigests = null;
  } else {
    final paths = <String>{};
    final digests = <String, Uint8List>{};
    for (final raw in inputs) {
      final decoded = _decodeInputView(raw);
      final rawPath = decoded.path;
      if (rawPath.isEmpty) continue;
      if (_isNormalizedRelative(rawPath)) {
        paths.add(rawPath);
        if (decoded.digest.isNotEmpty) {
          exactInputPathsWithDigest.add(rawPath);
          digests[rawPath] = decoded.digest;
        }
      } else {
        paths.add(rawPath);
        final norm = _normalize(rawPath);
        if (norm.isNotEmpty) paths.add(norm);
        if (decoded.digest.isNotEmpty) {
          exactInputPathsWithDigest.add(rawPath);
          digests[rawPath] = decoded.digest;
          final normFile = _normalizeFilePath(rawPath);
          digests.putIfAbsent(normFile, () => decoded.digest);
          if (norm.isNotEmpty) {
            digests.putIfAbsent(norm, () => decoded.digest);
            digests.putIfAbsent('./$norm', () => decoded.digest);
          }
        }
      }
    }
    workerInputPaths = paths;
    inputDigests = digests;
  }

  final roots = await _packageRoots(packagesFile, multiRootPrefix);
  final closure = await _readExcluded(
    closureExcluded,
    roots,
    multiRootPrefix,
    cache: cache,
    inputDigests: inputDigests,
  );
  final Set<String> vm;
  if (cache != null && extraLibraries.isEmpty) {
    vm = await cache.vmLibrariesOf(
      librariesJson,
      inputDigests,
      platform: librariesPlatform,
    );
  } else {
    final librariesMap = cache != null
        ? await cache.librariesJsonOf(librariesJson, inputDigests)
        : jsonDecode(await File(librariesJson).readAsString())
              as Map<String, dynamic>;
    vm = vmLibraries(
      librariesMap,
      platform: librariesPlatform,
      extraLibraries: extraLibraries,
    );
  }
  // Every kernel the closure indexes, by the key of each library it defines.
  final graph = <String, _Node>{};
  final stagedSources = <String, String>{};
  for (final dir in inputKmods) {
    if (!await _readIndex(
      dir,
      graph,
      log,
      stagedSources: stagedSources,
      cache: cache,
      inputDigests: inputDigests,
    )) {
      return 1;
    }
  }
  final declaredKeys = <String>{};
  final declaredRootPaths = <String>{};
  for (final raw in [...sources, ...inputSources]) {
    final key = _keyOfUri(raw, roots, multiRootPrefix);
    if (key != null) declaredKeys.add(key);
    for (final spelling in _inputSpellings(raw, multiRoots)) {
      declaredKeys.add(spelling);
    }
    if (!raw.contains(':') || isWindowsDrivePath(raw)) {
      declaredRootPaths.add(raw);
      final norm = _normalize(raw);
      if (norm.isNotEmpty) declaredRootPaths.add(norm);
      final normFile = _normalizeFilePath(raw);
      if (normFile.isNotEmpty) declaredRootPaths.add(normFile);
    }
  }
  final files = _Files(
    multiRoots.isEmpty ? const ['.'] : multiRoots,
    declaredKeys: declaredKeys,
    declaredRootPaths: declaredRootPaths,
    stagedRoots: stagedSources,
    workerInputPaths: workerInputPaths,
  );
  await Directory(output).create(recursive: true);
  if (outputOutline != null) {
    await Directory(outputOutline).create(recursive: true);
  }

  // A file that a dependency module defines is linked from that module, so this module
  // neither compiles it nor excludes it. An excluded file in the closure counts only
  // while no module of the closure defines it: then the module that defines it is the
  // copy the executable links.
  final inherited = <String, String>{
    for (final entry in closure.entries)
      if (!graph.containsKey(entry.key)) entry.key: entry.value,
  };
  final own = <String>[
    for (final uri in sources)
      if (!_definedBy(uri, graph, roots, multiRootPrefix)) uri,
  ];

  if (noDrop) {
    final entry = await _entrySources(
      sources,
      inherited,
      graph,
      roots,
      files,
      vm,
      multiRootPrefix,
    );
    if (entry.undeclared.isNotEmpty) {
      for (final missing in entry.undeclared) {
        log.writeln(
          'kernel_module: cannot compile $missing: '
          'source is not a declared input.',
        );
      }
      return 1;
    }
    final extraMultiRoots = <String>[];
    final seenStagedRoots = <String>{};
    final stagedInputs = <Uint8List>[];
    for (final key in entry.keys) {
      if (!files.isDeclaredInRoots(key)) {
        final stagedRoot = stagedSources[key];
        if (stagedRoot != null) {
          if (seenStagedRoots.add(stagedRoot)) {
            extraMultiRoots.add(stagedRoot);
          }
          if (inputs.isNotEmpty) {
            final stagedPath = '$stagedRoot/$key';
            if (!exactInputPathsWithDigest.contains(stagedPath)) {
              final knownDigest =
                  _lookupDigest(stagedPath, inputDigests) ??
                  await _digestOf(stagedPath);
              stagedInputs.add(_encodeInput(stagedPath, knownDigest));
            }
          }
        }
      }
    }
    const dill = 'entry.dill';
    final useIsolated = await _needsIsolatedMultiRoot(
      compiler,
      multiRoots,
      extraMultiRoots,
      entry.keys,
      files,
      vm,
    );
    ({String rootDir, List<Uint8List> inputs})? isolated;
    final ModuleOutcome outcome;
    try {
      if (useIsolated) {
        isolated = await _stageIsolatedMultiRoot(
          output,
          files,
          inputDigests,
          includeInputDigests: inputs.isNotEmpty || compiler is _Persistent,
        );
      }
      final entryBase = isolated != null
          ? _baseWithSingleMultiRoot(base, isolated.rootDir)
          : base;
      final callInputs = isolated != null
          ? (isolated.inputs.isEmpty ? inputs : [...inputs, ...isolated.inputs])
          : (stagedInputs.isEmpty ? inputs : [...inputs, ...stagedInputs]);
      outcome = await compiler.run(
        kernelWorkerArgs([
          ...entryBase,
          if (isolated == null)
            for (final root in extraMultiRoots) ...[_multiRootFlag, root],
          for (final d in neededDills(entry.imports, graph)) ...[
            '--input-summary',
            d,
          ],
          for (final source in entry.uris) ...['--source', source],
          '--output',
          '$output/$dill',
        ]),
        callInputs,
      );
    } finally {
      if (isolated != null) {
        final dir = Directory(_filePathOf(isolated.rootDir));
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }
    if (outcome.exitCode != 0) {
      log.write(outcome.output);
      return 1;
    }
    final entrySccs = [
      _Scc(dill: dill, keys: const [], uris: const [], imports: entry.imports),
    ];
    await _writeIndex(output, entrySccs);
    if (outputOutline != null) {
      final fullFile = File('$output/$dill');
      if (await fullFile.exists()) {
        final rawBytes = await fullFile.readAsBytes();
        final outlineBytes = stripDillToOutline(rawBytes);
        await File('$outputOutline/$dill').writeAsBytes(outlineBytes);
      }
      await _writeIndex(outputOutline, entrySccs);
    }
    await File(excludedPath).writeAsString('');
    return 0;
  }

  final keys = <String, String>{};
  final plan = _Plan();
  for (final uri in own) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) continue;
    if (!files.isDeclared(key)) {
      log.writeln(
        'kernel_module: cannot compile $uri ($key): '
        'source is not a declared input.',
      );
      return 1;
    }
    keys[uri] = key;
    plan.addOwn(key, uri);
  }
  await _adoptDeclaredPartPeers(
    own,
    keys,
    plan,
    inherited,
    graph,
    roots,
    files,
    vm,
    multiRootPrefix,
  );
  await _planImports(
    plan,
    keys,
    inherited,
    graph,
    roots,
    files,
    vm,
    log,
    multiRootPrefix,
  );

  var remaining = [
    for (final uri in own)
      if (!plan.isExcluded(keys[uri])) uri,
  ];
  var retried = false;
  var sccs = <_Scc>[];
  ({String rootDir, List<Uint8List> inputs})? isolated;
  try {
    while (true) {
      sccs = _componentsOf(remaining, keys, plan);
      // The kernels this attempt has written, by key. A later component links to them.
      final local = Map<String, _Node>.of(graph);
      ModuleOutcome? failure;
      var failedUris = const <String>[];
      for (final scc in sccs) {
        final extraMultiRoots = <String>[];
        final seenStagedRoots = <String>{};
        final stagedInputs = <Uint8List>[];
        for (final key in scc.keys) {
          if (!files.isDeclaredInRoots(key)) {
            final stagedRoot = stagedSources[key];
            if (stagedRoot != null) {
              if (seenStagedRoots.add(stagedRoot)) {
                extraMultiRoots.add(stagedRoot);
              }
              if (inputs.isNotEmpty) {
                final stagedPath = '$stagedRoot/$key';
                if (!exactInputPathsWithDigest.contains(stagedPath)) {
                  final knownDigest =
                      _lookupDigest(stagedPath, inputDigests) ??
                      await _digestOf(stagedPath);
                  stagedInputs.add(_encodeInput(stagedPath, knownDigest));
                }
              }
            }
          }
        }
        final useIsolated =
            isolated != null ||
            await _needsIsolatedMultiRoot(
              compiler,
              multiRoots,
              extraMultiRoots,
              scc.keys,
              files,
              vm,
            );
        if (useIsolated && isolated == null) {
          isolated = await _stageIsolatedMultiRoot(
            output,
            files,
            inputDigests,
            includeInputDigests: inputs.isNotEmpty || compiler is _Persistent,
          );
        }
        final summaryNodes = _neededNodes(scc.imports, local);
        final summaryInputs = <Uint8List>[];
        if (inputs.isNotEmpty || compiler is _Persistent) {
          for (final node in summaryNodes) {
            final encoded = node.encodedInput;
            if (encoded != null) {
              summaryInputs.add(encoded);
            }
          }
        }
        final dillPath = '$output/${scc.dill}';
        final sccBase = isolated != null
            ? _baseWithSingleMultiRoot(base, isolated.rootDir)
            : base;
        final extraInputs = [
          if (isolated != null) ...isolated.inputs else ...stagedInputs,
          ...summaryInputs,
        ];
        final outcome = await compiler.run(
          kernelWorkerArgs([
            ...sccBase,
            if (isolated == null)
              for (final root in extraMultiRoots) ...[_multiRootFlag, root],
            for (final node in summaryNodes) ...['--input-summary', node.dill],
            for (final uri in scc.uris) ...['--source', uri],
            '--output',
            dillPath,
          ]),
          extraInputs.isEmpty ? inputs : [...inputs, ...extraInputs],
        );
        if (outcome.exitCode != 0) {
          failure = outcome;
          failedUris = scc.uris;
          break;
        }
        var nodeDill = dillPath;
        Uint8List? nodeDillBytes;
        final dillFile = File(dillPath);
        if (await dillFile.exists()) {
          final rawBytes = await dillFile.readAsBytes();
          if (outputOutline != null) {
            final outlineBytes = stripDillToOutline(rawBytes);
            nodeDill = '$outputOutline/${scc.dill}';
            await File(nodeDill).writeAsBytes(outlineBytes);
            nodeDillBytes = outlineBytes;
            await dillFile.writeAsBytes(_stripSourceCodeFromDill(rawBytes));
          } else {
            final strippedBytes = _stripSourceCodeFromDill(rawBytes);
            await dillFile.writeAsBytes(strippedBytes);
            nodeDillBytes = strippedBytes;
          }
        }
        final node = _Node(nodeDill, scc.imports, dillBytes: nodeDillBytes);
        for (final key in scc.keys) {
          local[key] = node;
        }
      }
      if (failure == null) break;
      // The one retry: drop the own sources that failed, and their importers. The
      // components are then formed again from what remains.
      final verdict = _attribute(
        failure.output,
        failedUris,
        roots,
        multiRootPrefix,
      );
      if (retried ||
          verdict.unattributed ||
          verdict.outside ||
          verdict.failing.isEmpty) {
        log.write(failure.output);
        return 1;
      }
      retried = true;
      plan.exclude({
        for (final entry in verdict.failing.entries)
          entry.key: 'compile error: ${entry.value}',
      });
      remaining = [
        for (final uri in remaining)
          if (!plan.isExcluded(keys[uri])) uri,
      ];
    }
  } finally {
    if (isolated != null) {
      final dir = Directory(_filePathOf(isolated.rootDir));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }
  await _writeIndex(output, sccs);
  if (outputOutline != null) {
    final excludedKeys = <String>[];
    for (final uri in own) {
      final key = keys[uri];
      if (key == null || !plan.isExcluded(key)) continue;
      final text = await files.read(key);
      if (text == null) continue;
      final staged = File('$outputOutline/sources/$key');
      await staged.parent.create(recursive: true);
      await staged.writeAsString(text);
      excludedKeys.add(key);
    }
    excludedKeys.sort();
    await _writeIndex(outputOutline, sccs, excluded: excludedKeys);
  }

  // Written even when nothing is excluded: the sidecar is a declared output. Its
  // `#` line is a count for the build log, and each excluded source is listed under
  // its `package:` URI and its multi-root URI, with the reason.
  final lines = StringBuffer()
    ..writeln(
      '# ${remaining.length} of ${own.length} sources compile; the others '
      'are excluded for the VM.',
    );
  for (final uri in own) {
    final key = keys[uri];
    final reason = plan.reasonOf(key);
    if (key == null || reason == null) continue;
    lines.writeln('$uri\t$reason');
    if (!uri.startsWith(multiRootPrefix)) {
      lines.writeln('$multiRootPrefix$key\t$reason');
    }
  }
  await File(excludedPath).writeAsString(lines.toString());
  return 0;
}

/// One kernel a module writes: the sources it compiles, and the keys it imports.
class _Scc {
  _Scc({
    required this.dill,
    required this.keys,
    required this.uris,
    required this.imports,
  });

  /// The file name within the module's directory.
  final String dill;

  /// The keys of the libraries (and parts) this kernel defines, sorted.
  final List<String> keys;

  /// The URIs the kernel compiles each of `keys` under.
  final List<String> uris;

  /// The keys this kernel imports or exports from outside itself, sorted.
  final List<String> imports;
}

/// A kernel an index names: its file, and the keys it imports.
class _Node {
  _Node(this.dill, this.imports, {Uint8List? dillBytes})
    : _dillBytes = dillBytes;

  final String dill;
  final List<String> imports;
  Uint8List? _dillBytes;
  Uint8List? _encodedInput;

  /// Encoded protobuf `Input` message for an intra-module SCC kernel written
  /// during this compile, computed lazily in memory without re-reading disk.
  Uint8List? get encodedInput {
    final cached = _encodedInput;
    if (cached != null) return cached;
    final bytes = _dillBytes;
    if (bytes == null) return null;
    _dillBytes = null;
    return _encodedInput = _encodeInput(dill, sha256Of(bytes));
  }
}

class _IndexedScc {
  const _IndexedScc({
    required this.dill,
    required this.defines,
    required this.imports,
  });

  final String dill;
  final List<String> defines;
  final List<String> imports;
}

class _ParsedIndex {
  const _ParsedIndex({required this.sccs, required this.excluded});

  final List<_IndexedScc> sccs;
  final List<String> excluded;
}

class _ModuleCacheEntry<T> {
  _ModuleCacheEntry({
    required this.value,
    required this.inputDigest,
    required this.contentSha256,
    required this.byteSize,
    required this.tick,
  });

  final T value;
  final Uint8List? inputDigest;
  final Uint8List? contentSha256;
  final int byteSize;
  int tick;
  Map<String, Set<String>>? vmByPlatform;
}

bool _isNormalizedRelative(String path) {
  final len = path.length;
  if (len == 0) return false;
  if (isWindowsDrivePath(path)) return false;
  if (path.codeUnitAt(0) == 0x2f ||
      path.codeUnitAt(0) == 0x5c ||
      path.codeUnitAt(len - 1) == 0x2f ||
      path.codeUnitAt(len - 1) == 0x5c) {
    return false;
  }
  var segStart = 0;
  for (var i = 0; i <= len; i++) {
    if (i < len && path.codeUnitAt(i) == 0x5c) return false;
    if (i == len || path.codeUnitAt(i) == 0x2f) {
      final segLen = i - segStart;
      if (segLen == 0) return false;
      if (segLen == 1 && path.codeUnitAt(segStart) == 0x2e) return false;
      if (segLen == 2 &&
          path.codeUnitAt(segStart) == 0x2e &&
          path.codeUnitAt(segStart + 1) == 0x2e) {
        return false;
      }
      segStart = i + 1;
    }
  }
  return true;
}

String _normalizeFilePath(String path) {
  if (_isNormalizedRelative(path)) return path;
  if (path.isEmpty) return '.';
  final slashPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  String? drivePrefix;
  var rest = slashPath;
  if (isWindowsDrivePath(slashPath)) {
    drivePrefix = '${slashPath.substring(0, 2)}/';
    rest = slashPath.substring(2);
  }
  final isAbs = drivePrefix != null || rest.startsWith('/');
  final parts = rest.split('/');
  final stack = <String>[];
  for (final part in parts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (stack.isNotEmpty && stack.last != '..') {
        stack.removeLast();
      } else if (!isAbs) {
        stack.add('..');
      }
    } else {
      stack.add(part);
    }
  }
  if (stack.isEmpty) return drivePrefix ?? (isAbs ? '/' : '.');
  final joined = stack.join('/');
  if (drivePrefix != null) return '$drivePrefix$joined';
  return isAbs ? '/$joined' : joined;
}

Uint8List? _lookupDigest(String path, Map<String, Uint8List>? inputDigests) {
  if (inputDigests == null) return null;
  final direct = inputDigests[path];
  if (direct != null && direct.isNotEmpty) return direct;
  if (_isNormalizedRelative(path)) {
    final dotHit = inputDigests['./$path'];
    if (dotHit != null && dotHit.isNotEmpty) return dotHit;
    return null;
  }
  final normFile = _normalizeFilePath(path);
  if (normFile != path) {
    final hit = inputDigests[normFile];
    if (hit != null && hit.isNotEmpty) return hit;
  }
  final relNorm = _normalize(path);
  if (relNorm.isNotEmpty) {
    final relHit = inputDigests[relNorm];
    if (relHit != null && relHit.isNotEmpty) return relHit;
    if (!relNorm.startsWith('/')) {
      final dotHit = inputDigests['./$relNorm'];
      if (dotHit != null && dotHit.isNotEmpty) return dotHit;
    }
  }
  return null;
}

/// Byte-bounded cache of parsed `index.json` manifests, `.vm_excluded.txt`
/// sidecars, and SDK `libraries.json` across persistent-worker requests.
///
/// Validates entries against the file's digest in `WorkRequest.inputs` (which
/// Bazel 9.3.0 populates for all constituent files of `.kmod` / `.koutline`
/// tree artifacts), falling back to reading from disk and checking `sha256Of`
/// when no digest is present in `WorkRequest.inputs`.
class KernelModuleCache {
  KernelModuleCache({this.maxCacheBytes = defaultMaxCacheBytes});

  static const int defaultMaxCacheBytes = 32 * 1024 * 1024;

  final int maxCacheBytes;
  final _indexCache = <String, _ModuleCacheEntry<_ParsedIndex>>{};
  final _librariesCache = <String, _ModuleCacheEntry<Map<String, dynamic>>>{};
  final _excludedCache = <String, _ModuleCacheEntry<List<String>>>{};
  int _indexBytesTotal = 0;
  int _librariesBytesTotal = 0;
  int _excludedBytesTotal = 0;
  int _clock = 0;

  int get indexBytes => _indexBytesTotal;
  int get librariesBytes => _librariesBytesTotal;
  int get excludedBytes => _excludedBytesTotal;
  int get totalBytes =>
      _indexBytesTotal + _librariesBytesTotal + _excludedBytesTotal;
  int get indexEntryCount => _indexCache.length;
  int get librariesEntryCount => _librariesCache.length;
  int get excludedEntryCount => _excludedCache.length;

  static Uint8List _unpin(Uint8List bytes) =>
      bytes.buffer.lengthInBytes == bytes.lengthInBytes
      ? bytes
      : Uint8List.fromList(bytes);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _evictForBudget(int incomingBytes) {
    while (totalBytes + incomingBytes > maxCacheBytes) {
      String? oldestIndexKey;
      int? oldestIndexTick;
      if (_indexCache.isNotEmpty) {
        final first = _indexCache.entries.first;
        oldestIndexKey = first.key;
        oldestIndexTick = first.value.tick;
      }

      String? oldestLibKey;
      int? oldestLibTick;
      if (_librariesCache.isNotEmpty) {
        final first = _librariesCache.entries.first;
        oldestLibKey = first.key;
        oldestLibTick = first.value.tick;
      }

      String? oldestExclKey;
      int? oldestExclTick;
      if (_excludedCache.isNotEmpty) {
        final first = _excludedCache.entries.first;
        oldestExclKey = first.key;
        oldestExclTick = first.value.tick;
      }

      if (oldestIndexTick == null &&
          oldestLibTick == null &&
          oldestExclTick == null) {
        break;
      }

      var minTick = oldestIndexTick ?? oldestLibTick ?? oldestExclTick!;
      if (oldestLibTick != null && oldestLibTick < minTick) {
        minTick = oldestLibTick;
      }
      if (oldestExclTick != null && oldestExclTick < minTick) {
        minTick = oldestExclTick;
      }

      if (oldestIndexTick != null && oldestIndexTick == minTick) {
        final removed = _indexCache.remove(oldestIndexKey!)!;
        _indexBytesTotal -= removed.byteSize;
      } else if (oldestExclTick != null && oldestExclTick == minTick) {
        final removed = _excludedCache.remove(oldestExclKey!)!;
        _excludedBytesTotal -= removed.byteSize;
      } else if (oldestLibTick != null) {
        final removed = _librariesCache.remove(oldestLibKey!)!;
        _librariesBytesTotal -= removed.byteSize;
      }
    }
  }

  Future<_ModuleCacheEntry<Map<String, dynamic>>> _librariesEntryOf(
    String path,
    Map<String, Uint8List>? inputDigests,
  ) async {
    final key = _normalizeFilePath(path);
    final digest = _lookupDigest(path, inputDigests);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _librariesCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _librariesCache[key] = cached;
        return cached;
      }
      _librariesBytesTotal -= cached.byteSize;
    }

    final bytes = await File(path).readAsBytes();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxCacheBytes) {
        _evictForBudget(entryBytes);
        cached.tick = ++_clock;
        _librariesCache[key] = cached;
        _librariesBytesTotal += entryBytes;
      }
      return cached;
    }

    final parsed = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final entry = _ModuleCacheEntry(
      value: parsed,
      inputDigest: hasDigest ? _unpin(digest) : null,
      contentSha256: contentSha256,
      byteSize: entryBytes,
      tick: ++_clock,
    );
    if (entryBytes <= maxCacheBytes) {
      _evictForBudget(entryBytes);
      _librariesCache[key] = entry;
      _librariesBytesTotal += entryBytes;
    }
    return entry;
  }

  Future<Map<String, dynamic>> librariesJsonOf(
    String path,
    Map<String, Uint8List>? inputDigests,
  ) async => (await _librariesEntryOf(path, inputDigests)).value;

  Future<Set<String>> vmLibrariesOf(
    String path,
    Map<String, Uint8List>? inputDigests, {
    required String platform,
  }) async {
    final entry = await _librariesEntryOf(path, inputDigests);
    final map = entry.vmByPlatform ??= <String, Set<String>>{};
    return map[platform] ??= vmLibraries(entry.value, platform: platform);
  }

  Future<List<String>> excludedLinesOf(
    String path,
    Map<String, Uint8List>? inputDigests,
  ) async {
    final key = _normalizeFilePath(path);
    final digest = _lookupDigest(path, inputDigests);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _excludedCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _excludedCache[key] = cached;
        return cached.value;
      }
      _excludedBytesTotal -= cached.byteSize;
    }

    final bytes = await File(path).readAsBytes();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxCacheBytes) {
        _evictForBudget(entryBytes);
        cached.tick = ++_clock;
        _excludedCache[key] = cached;
        _excludedBytesTotal += entryBytes;
      }
      return cached.value;
    }

    final text = utf8.decode(bytes);
    final uris = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty || line.codeUnitAt(0) == 0x23) continue;
      final tab = line.indexOf('\t');
      uris.add(tab < 0 ? line : line.substring(0, tab));
    }
    final stored = uris.isEmpty ? const <String>[] : uris;
    if (entryBytes <= maxCacheBytes) {
      _evictForBudget(entryBytes);
      _excludedCache[key] = _ModuleCacheEntry(
        value: stored,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: contentSha256,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _excludedBytesTotal += entryBytes;
    }
    return stored;
  }

  Future<_ParsedIndex?> _indexOf(
    String dir,
    Map<String, Uint8List>? inputDigests,
  ) async {
    final indexPath = '$dir/$_indexName';
    final key = _normalizeFilePath(indexPath);
    final digest = _lookupDigest(indexPath, inputDigests);
    final hasDigest = digest != null && digest.isNotEmpty;
    final cached = _indexCache.remove(key);
    if (cached != null) {
      if (hasDigest &&
          cached.inputDigest != null &&
          _sameBytes(digest, cached.inputDigest!)) {
        cached.tick = ++_clock;
        _indexCache[key] = cached;
        return cached.value;
      }
      _indexBytesTotal -= cached.byteSize;
    }

    final file = File(indexPath);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    final entryBytes = bytes.length;
    final contentSha256 = hasDigest ? null : sha256Of(bytes);
    if (!hasDigest &&
        cached != null &&
        cached.byteSize == entryBytes &&
        cached.contentSha256 != null &&
        _sameBytes(contentSha256!, cached.contentSha256!)) {
      if (entryBytes <= maxCacheBytes) {
        _evictForBudget(entryBytes);
        cached.tick = ++_clock;
        _indexCache[key] = cached;
        _indexBytesTotal += entryBytes;
      }
      return cached.value;
    }

    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final sccs = [
      for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>())
        _IndexedScc(
          dill: scc['dill'] as String,
          defines: (scc['defines'] as List).cast<String>(),
          imports: (scc['imports'] as List).cast<String>(),
        ),
    ];
    final excluded = json['excluded'] is List
        ? (json['excluded'] as List).cast<String>()
        : const <String>[];
    final parsed = _ParsedIndex(sccs: sccs, excluded: excluded);
    if (entryBytes <= maxCacheBytes) {
      _evictForBudget(entryBytes);
      _indexCache[key] = _ModuleCacheEntry(
        value: parsed,
        inputDigest: hasDigest ? _unpin(digest) : null,
        contentSha256: contentSha256,
        byteSize: entryBytes,
        tick: ++_clock,
      );
      _indexBytesTotal += entryBytes;
    }
    return parsed;
  }
}

/// The components of the remaining own sources, dependencies first. Each is one
/// kernel, named by its position: `<n>.dill`. Libraries that import each other, and
/// the parts of a library, form one component.
List<_Scc> _componentsOf(
  List<String> remaining,
  Map<String, String> keys,
  _Plan plan,
) {
  final uriOf = <String, String>{};
  for (final uri in remaining) {
    uriOf.putIfAbsent(keys[uri] ?? 'uri:$uri', () => uri);
  }
  final nodes = uriOf.keys.toList()..sort();
  final members = uriOf.keys.toSet();
  Iterable<String> successors(String key) => plan
      .importsOf(key)
      .where((target) => target != key && members.contains(target));
  final components = stronglyConnected(nodes, successors);
  return [
    for (var i = 0; i < components.length; i++)
      _sccOf('$i.dill', components[i], uriOf, plan),
  ];
}

_Scc _sccOf(
  String dill,
  List<String> keys,
  Map<String, String> uriOf,
  _Plan plan,
) {
  final own = keys.toSet();
  final imports = <String>{
    for (final key in keys) ...plan.importsOf(key),
  }.where((target) => !own.contains(target)).toList()..sort();
  return _Scc(
    dill: dill,
    keys: keys,
    uris: [for (final key in keys) uriOf[key]!],
    imports: imports,
  );
}

/// The strongly connected components of a graph, each sorted, in an order where every
/// component follows the components it reaches. Tarjan's algorithm emits a component
/// once everything it reaches is emitted, which gives that order directly. Nodes and
/// successors are visited in sorted order, so the same graph always gives the same
/// components in the same order.
List<List<String>> stronglyConnected(
  List<String> nodes,
  Iterable<String> Function(String) successors,
) {
  final index = <String, int>{};
  final low = <String, int>{};
  final onStack = <String>{};
  final stack = <String>[];
  final out = <List<String>>[];
  void visit(String v) {
    index[v] = low[v] = index.length;
    stack.add(v);
    onStack.add(v);
    for (final w in successors(v)) {
      if (!index.containsKey(w)) {
        visit(w);
        final lowW = low[w]!;
        if (lowW < low[v]!) low[v] = lowW;
      } else if (onStack.contains(w)) {
        final indexW = index[w]!;
        if (indexW < low[v]!) low[v] = indexW;
      }
    }
    if (low[v] == index[v]) {
      final component = <String>[];
      String w;
      do {
        w = stack.removeLast();
        onStack.remove(w);
        component.add(w);
      } while (w != v);
      out.add(component..sort());
    }
  }

  for (final node in nodes) {
    if (!index.containsKey(node)) visit(node);
  }
  return out;
}

/// The kernels a dependency module needs to compile against: every kernel reached from
/// `roots` through the imports of the kernels they name. Sorted, so the arguments of
/// a compile do not change from one build to the next.
List<String> neededDills(Iterable<String> roots, Map<String, _Node> graph) => [
  for (final node in _neededNodes(roots, graph)) node.dill,
];

List<_Node> _neededNodes(Iterable<String> roots, Map<String, _Node> graph) {
  final byDill = <String, _Node>{};
  final visited = <String>{};
  final queue = Queue<String>.of(roots);
  while (queue.isNotEmpty) {
    final key = queue.removeFirst();
    if (!visited.add(key)) continue;
    final node = graph[key];
    if (node == null) continue;
    if (!byDill.containsKey(node.dill)) {
      byDill[node.dill] = node;
      queue.addAll(node.imports);
    }
  }
  final sortedDills = byDill.keys.toList()..sort();
  return [for (final dill in sortedDills) byDill[dill]!];
}

/// Adds the kernels that the module directory `dir` indexes to `graph`, by each key
/// they define. Returns false, after saying why, when the index is missing.
Future<bool> _readIndex(
  String dir,
  Map<String, _Node> graph,
  StringBuffer log, {
  Map<String, String>? stagedSources,
  KernelModuleCache? cache,
  Map<String, Uint8List>? inputDigests,
}) async {
  if (cache != null) {
    final parsed = await cache._indexOf(dir, inputDigests);
    if (parsed == null) {
      log.writeln('kernel_module: $dir has no $_indexName.');
      return false;
    }
    for (final scc in parsed.sccs) {
      final node = _Node('$dir/${scc.dill}', scc.imports);
      for (final key in scc.defines) {
        graph.putIfAbsent(key, () => node);
      }
    }
    if (stagedSources != null && parsed.excluded.isNotEmpty) {
      for (final key in parsed.excluded) {
        stagedSources.putIfAbsent(key, () => '$dir/sources');
      }
    }
    return true;
  }
  final file = File('$dir/$_indexName');
  if (!await file.exists()) {
    log.writeln('kernel_module: $dir has no $_indexName.');
    return false;
  }
  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>()) {
    final node = _Node(
      '$dir/${scc['dill']}',
      (scc['imports'] as List).cast<String>(),
    );
    for (final key in (scc['defines'] as List).cast<String>()) {
      graph.putIfAbsent(key, () => node);
    }
  }
  if (stagedSources != null && json['excluded'] is List) {
    for (final key in (json['excluded'] as List).cast<String>()) {
      stagedSources.putIfAbsent(key, () => '$dir/sources');
    }
  }
  return true;
}

Future<void> _writeIndex(
  String dir,
  List<_Scc> sccs, {
  List<String> excluded = const [],
}) async {
  final json = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'sccs': [
      for (final scc in sccs)
        {'dill': scc.dill, 'defines': scc.keys, 'imports': scc.imports},
    ],
    if (excluded.isNotEmpty) 'excluded': excluded,
  });
  await File('$dir/$_indexName').writeAsString('$json\n');
}

/// The import graph of a module's own sources, and which of them are excluded.
class _Plan {
  /// The URI each own source was given, by key.
  final Map<String, String> _uriOf = {};

  /// The own sources that import each own source, by key, in the order found.
  final Map<String, List<String>> _importers = {};

  /// The excluded own sources, by key, with the reason. In the order excluded.
  final Map<String, String> _excluded = {};

  /// What each source imports or exports, by key: own sources and dependencies alike.
  final Map<String, Set<String>> _imports = {};

  void addOwn(String key, String uri) => _uriOf.putIfAbsent(key, () => uri);

  bool isOwn(String key) => _uriOf.containsKey(key);

  /// Records that `importer` imports or exports `imported`, an own source.
  void addImporter({required String imported, required String importer}) {
    final list = _importers[imported] ??= [];
    if (!list.contains(importer)) list.add(importer);
  }

  /// Records that `importer` imports or exports `target`, whether or not it is own.
  void addImport({required String importer, required String target}) {
    (_imports[importer] ??= {}).add(target);
  }

  /// The keys `key` imports or exports, sorted.
  List<String> importsOf(String key) =>
      (_imports[key] ?? const <String>{}).toList()..sort();

  bool isExcluded(String? key) => key != null && _excluded.containsKey(key);

  String? reasonOf(String? key) => key == null ? null : _excluded[key];

  /// Excludes each seed, then every own source that imports an excluded one.
  void exclude(Map<String, String> seeds) {
    final queue = Queue<String>();
    seeds.forEach((key, reason) {
      if (isOwn(key) && !_excluded.containsKey(key)) {
        _excluded[key] = reason;
        queue.add(key);
      }
    });
    while (queue.isNotEmpty) {
      final key = queue.removeFirst();
      for (final importer in _importers[key] ?? const <String>[]) {
        if (_excluded.containsKey(importer)) continue;
        _excluded[importer] = 'imports ${_uriOf[key]}, which is excluded';
        queue.add(importer);
      }
    }
  }
}

/// Adopts declared non-graph peer files (`--input-source` or staged `.koutline`
/// sources) that complete a `part` / `part of` library unit with this module's
/// own or inherited excluded sources.
Future<void> _adoptDeclaredPartPeers(
  List<String> own,
  Map<String, String> keys,
  _Plan plan,
  Map<String, String> inherited,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  String multiRootPrefix,
) async {
  var hasPartDirective = false;
  for (final key in <String>{...keys.values, ...inherited.keys}) {
    final scan = await files.scan(key, vm);
    if (scan == null) continue;
    if (scan.partOfLibrary != null ||
        scan.refs.any((r) => r.isPart || r.isPartOf)) {
      hasPartDirective = true;
      break;
    }
  }
  if (!hasPartDirective) return;

  final candidates = <String>{
    ...keys.values,
    for (final key in files.declaredKeys)
      if (!graph.containsKey(key)) key,
  };
  final scans = <String, ScanResult>{};
  final libraryByName = <String, String>{};
  for (final key in candidates) {
    final scan = await files.scan(key, vm);
    if (scan == null) continue;
    scans[key] = scan;
    if (scan.libraryName != null) {
      libraryByName.putIfAbsent(scan.libraryName!, () => key);
    }
  }

  final partsOf = <String, List<String?>>{};
  final hasPartOf = <String>{};
  final parentOf = <String, String?>{};
  scans.forEach((key, scan) {
    if (scan.partOfLibrary != null) {
      hasPartOf.add(key);
      parentOf[key] = libraryByName[scan.partOfLibrary!];
    }
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (ref.isPart) {
        (partsOf[key] ??= []).add(target);
      } else if (ref.isPartOf) {
        hasPartOf.add(key);
        parentOf[key] = target;
      }
    }
  });

  final resolvedPartsOf = <String, Set<String>>{
    for (final entry in partsOf.entries)
      entry.key: {for (final target in entry.value) ?target},
  };
  final sortedRoots = scans.keys.toList()..sort();
  for (final root in sortedRoots) {
    if (hasPartOf.contains(root)) continue;
    final directParts = partsOf[root];
    if (directParts == null || directParts.isEmpty) continue;
    final unit = <String>[root];
    final seen = <String>{root};
    final queue = Queue<String>()..add(root);
    var complete = true;
    while (queue.isNotEmpty && complete) {
      final current = queue.removeFirst();
      for (final partKey in partsOf[current] ?? const <String?>[]) {
        if (partKey == null ||
            !scans.containsKey(partKey) ||
            !hasPartOf.contains(partKey)) {
          complete = false;
          break;
        }
        final parent = parentOf[partKey];
        if (parent == null ||
            !seen.contains(parent) ||
            !_reachesViaPart(parent, partKey, resolvedPartsOf)) {
          complete = false;
          break;
        }
        if (seen.add(partKey)) {
          unit.add(partKey);
          queue.add(partKey);
        }
      }
    }
    if (!complete ||
        !unit.any((m) => plan.isOwn(m) || inherited.containsKey(m))) {
      continue;
    }
    for (final member in unit) {
      if (plan.isOwn(member)) continue;
      final uri = _packageUriOf(
        member,
        inherited[member] ?? '$multiRootPrefix$member',
        roots,
      );
      own.add(uri);
      keys[uri] = member;
      plan.addOwn(member, uri);
      inherited.remove(member);
    }
  }
}

/// Whether `parent` reaches `partKey` through one or more `part` directives in
/// `declaredPartsOf`.
bool _reachesViaPart(
  String parent,
  String partKey,
  Map<String, Set<String>> declaredPartsOf,
) {
  final visited = <String>{parent};
  final queue = Queue<String>()..add(parent);
  while (queue.isNotEmpty) {
    final current = queue.removeFirst();
    final parts = declaredPartsOf[current];
    if (parts == null) continue;
    if (parts.contains(partKey)) return true;
    for (final next in parts) {
      if (visited.add(next)) queue.add(next);
    }
  }
  return false;
}

/// Records each own source's imports in `plan`, and excludes the sources a VM
/// cannot compile: those that import a `dart:` library the VM lacks, a `package:` that
/// the module's config does not name, a part or parent library that is not an own
/// source, or a file that `inherited` lists as excluded.
Future<void> _planImports(
  _Plan plan,
  Map<String, String> keys,
  Map<String, String> inherited,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  StringBuffer log,
  String multiRootPrefix,
) async {
  final direct = <String, String>{};
  final scans = <String, ScanResult>{};
  final libraryKeyByName = <String, String>{};
  final declaredPartsOf = <String, Set<String>>{};
  for (final key in keys.values) {
    final scan = await files.scan(key, vm);
    if (scan == null) {
      // Not readable here, or not a directive prologue the scanner can follow. The
      // compiler decides, and a failure in it is attributed or fails the action.
      log.writeln('kernel_module: could not read the directives of $key.');
      continue;
    }
    scans[key] = scan;
    if (scan.libraryName != null) {
      libraryKeyByName.putIfAbsent(scan.libraryName!, () => key);
    }
    for (final ref in scan.refs) {
      if (!ref.isPart || ref.uri.startsWith('dart:')) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (target != null) {
        (declaredPartsOf[key] ??= {}).add(target);
      }
    }
  }
  for (final entry in scans.entries) {
    final key = entry.key;
    final scan = entry.value;
    if (scan.partOfLibrary != null) {
      final libName = scan.partOfLibrary!;
      final parent = libraryKeyByName[libName];
      if (parent == null ||
          !plan.isOwn(parent) ||
          !_reachesViaPart(parent, key, declaredPartsOf)) {
        direct.putIfAbsent(
          key,
          () => 'its library $libName is not an input of this module',
        );
      } else {
        plan.addImport(importer: key, target: parent);
        plan.addImporter(imported: parent, importer: key);
        plan.addImporter(imported: key, importer: parent);
        plan.addImport(importer: parent, target: key);
      }
    }
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) {
        if (!vm.contains(ref.uri.substring('dart:'.length))) {
          direct.putIfAbsent(key, () => '${ref.uri} is not a VM library');
        }
        continue;
      }
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (target == null) {
        // A `package:` the module's config does not name. Other schemes are not Dart
        // sources this module can read, and resolve to null without a rule of their own.
        if (ref.isPartOf) {
          direct.putIfAbsent(
            key,
            () => 'its library ${ref.uri} is not an input of this module',
          );
        } else if (ref.isPart) {
          direct.putIfAbsent(
            key,
            () => 'its part ${ref.uri} is not an input of this module',
          );
        } else if (ref.uri.startsWith('package:')) {
          direct.putIfAbsent(
            key,
            () => '${ref.uri} names a package this module does not have',
          );
        }
        continue;
      }
      if (ref.isPartOf) {
        if (!plan.isOwn(target) ||
            !_reachesViaPart(target, key, declaredPartsOf)) {
          direct.putIfAbsent(
            key,
            () => 'its library ${ref.uri} is not an input of this module',
          );
          continue;
        }
        plan.addImport(importer: key, target: target);
        plan.addImporter(imported: target, importer: key);
        plan.addImporter(imported: key, importer: target);
        plan.addImport(importer: target, target: key);
        continue;
      }
      plan.addImport(importer: key, target: target);
      if (ref.isPart && !plan.isOwn(target)) {
        direct.putIfAbsent(
          key,
          () => 'its part ${ref.uri} is not an input of this module',
        );
        continue;
      }
      if (plan.isOwn(target)) {
        plan.addImporter(imported: target, importer: key);
        // A part follows its library both ways.
        if (ref.isPart) {
          plan.addImporter(imported: key, importer: target);
          plan.addImport(importer: target, target: key);
        }
      } else if (inherited.containsKey(target)) {
        direct.putIfAbsent(key, () => 'imports ${ref.uri}, which is excluded');
      } else if (!graph.containsKey(target)) {
        direct.putIfAbsent(
          key,
          () => 'imports ${ref.uri}, which is not in this module closure',
        );
      }
    }
  }
  plan.exclude(direct);
}

/// Whether the source at `uri` is one a module of the closure defines, so that this
/// module need not compile it. `graph` holds the keys the closure's modules define.
bool _definedBy(
  String uri,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final key = _keyOfUri(uri, roots, multiRootPrefix);
  return key != null && graph.containsKey(key);
}

/// What the entry module compiles, and what it imports.
class _EntrySources {
  _EntrySources(this.uris, this.imports, this.keys, this.undeclared);

  /// The URIs the entry compiles: its own sources, and each excluded file it reaches.
  final List<String> uris;

  /// The keys of every library the entry's sources import, sorted. The entry links
  /// against the kernels these reach.
  final List<String> imports;

  /// The keys of all sources in [uris].
  final List<String> keys;

  /// Any source reached by the entry module that is not a declared input.
  final List<String> undeclared;
}

/// The sources the entry module compiles: its own, and each excluded file it reaches.
/// An excluded file is compiled from source here, so the compiler reports its genuine
/// VM error. Every other file it reaches is in a module.
class _EntryEdge {
  _EntryEdge(this.from, this.uri, this.target);

  final String from;
  final String uri;
  final String target;
}

Future<_EntrySources> _entrySources(
  List<String> sources,
  Map<String, String> closure,
  Map<String, _Node> graph,
  Map<String, _PackageRoot> roots,
  _Files files,
  Set<String> vm,
  String multiRootPrefix,
) async {
  final out = <String>[];
  final ownUris = <String, String>{};
  final imports = <String>{};
  final seen = <String>{};
  final queue = Queue<String>();
  final edges = <_EntryEdge>[];
  final undeclared = <String>[];
  Map<String, String>? declaredLibraryByName;
  Future<String?> findLibraryByName(String name) async {
    if (declaredLibraryByName == null) {
      final map = <String, String>{};
      for (final candidate in <String>{
        ...closure.keys,
        ...files.declaredKeys,
      }) {
        final scan = await files.scan(candidate, vm);
        if (scan?.libraryName != null) {
          map.putIfAbsent(scan!.libraryName!, () => candidate);
        }
      }
      declaredLibraryByName = map;
    }
    return declaredLibraryByName![name];
  }

  for (final uri in sources) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) {
      out.add(uri);
    } else {
      ownUris.putIfAbsent(key, () => uri);
      if (seen.add(key)) queue.add(key);
    }
  }
  while (queue.isNotEmpty) {
    final key = queue.removeFirst();
    if (!files.isDeclared(key)) {
      undeclared.add('${ownUris[key] ?? key} ($key)');
      continue;
    }
    final text = await files.read(key);
    if (text == null) {
      undeclared.add('${ownUris[key] ?? key} ($key)');
      continue;
    }
    final scan = await files.scan(key, vm);
    if (scan == null) continue;
    if (scan.partOfLibrary != null) {
      final target = await findLibraryByName(scan.partOfLibrary!);
      if (target == null) {
        undeclared.add(
          '${ownUris[key] ?? key} (part of ${scan.partOfLibrary!})',
        );
      } else {
        final uri =
            closure[target] ??
            _packageUriOf(target, '$multiRootPrefix$target', roots);
        edges.add(_EntryEdge(key, uri, target));
        imports.add(target);
        if (seen.add(target)) {
          ownUris.putIfAbsent(target, () => uri);
          queue.add(target);
        }
      }
    }
    for (final ref in scan.refs) {
      if (ref.uri.startsWith('dart:')) continue;
      final target = _resolveUri(ref.uri, key, roots, multiRootPrefix);
      if (target == null) continue;
      edges.add(_EntryEdge(key, ref.uri, target));
      imports.add(target);
      if (!seen.add(target)) continue;
      final uri =
          closure[target] ??
          ((!graph.containsKey(target) || ref.isPart || ref.isPartOf)
              ? _packageUriOf(target, '$multiRootPrefix$target', roots)
              : null);
      if (uri == null) continue;
      ownUris.putIfAbsent(target, () => uri);
      queue.add(target);
    }
  }
  imports.removeAll(ownUris.keys);

  final usedAsRaw = <String>{};
  final usedAsPackage = <String>{};
  ownUris.forEach((key, uri) {
    final pkgUri = _packageUriOf(key, uri, roots);
    if (pkgUri == uri) {
      usedAsRaw.add(key);
    } else if (uri.startsWith('package:')) {
      usedAsPackage.add(key);
    }
  });
  for (final edge in edges) {
    if (!ownUris.containsKey(edge.target)) continue;
    if (edge.uri.startsWith('package:')) {
      usedAsPackage.add(edge.target);
    } else if (edge.uri.startsWith(multiRootPrefix)) {
      usedAsRaw.add(edge.target);
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final edge in edges) {
      if (!ownUris.containsKey(edge.target) || edge.uri.contains(':')) continue;
      if (usedAsRaw.contains(edge.from) && usedAsRaw.add(edge.target)) {
        changed = true;
      }
    }
  }
  ownUris.forEach((key, uri) {
    if (_packageUriOf(key, uri, roots) != uri && !usedAsRaw.contains(key)) {
      usedAsPackage.add(key);
    }
  });
  changed = true;
  while (changed) {
    changed = false;
    for (final edge in edges) {
      if (!ownUris.containsKey(edge.target) || edge.uri.contains(':')) continue;
      final targetUri = ownUris[edge.target]!;
      if (usedAsPackage.contains(edge.from) &&
          _packageUriOf(edge.target, targetUri, roots) != targetUri &&
          usedAsPackage.add(edge.target)) {
        changed = true;
      }
    }
  }
  ownUris.forEach((key, uri) {
    final pkgUri = _packageUriOf(key, uri, roots);
    if (pkgUri == uri) {
      out.add(uri);
      return;
    }
    if (usedAsPackage.contains(key) || !usedAsRaw.contains(key)) {
      out.add(pkgUri);
    }
    if (usedAsRaw.contains(key)) {
      final rawUri = uri.startsWith(multiRootPrefix)
          ? uri
          : '$multiRootPrefix$key';
      if (rawUri != pkgUri) out.add(rawUri);
    }
  });
  return _EntrySources(
    out,
    imports.toList()..sort(),
    ownUris.keys.toList(),
    undeclared,
  );
}

/// The `package:` URI of the file with `key`, when a package names it under its
/// `lib/`, and otherwise `uri`. An importer names such a library by its `package:`
/// URI, and `--exclude-non-sources` emits a library only under the URI it was given,
/// so an entry compiles its own `lib/` files under that URI too.
String _packageUriOf(String key, String uri, Map<String, _PackageRoot> roots) {
  String? best;
  var bestLength = -1;
  roots.forEach((name, root) {
    final prefix = '${root.path}${root.packageUri}';
    if (key.startsWith(prefix) && prefix.length > bestLength) {
      best = 'package:$name/${key.substring(prefix.length)}';
      bestLength = prefix.length;
    }
  });
  return best ?? uri;
}

/// The result of attributing a failing compile's diagnostics to own sources.
class _Verdict {
  const _Verdict({
    this.failing = const {},
    this.outside = false,
    this.unattributed = false,
  });

  /// Each own source with an error, by key, mapped to its first error message.
  final Map<String, String> failing;

  /// True when an error is located in a file that is not one of the own sources.
  final bool outside;

  /// True when a diagnostic names no location the tool can read.
  final bool unattributed;
}

_Verdict _attribute(
  String output,
  List<String> uris,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final keyOfSpelling = <String, String>{};
  for (final uri in uris) {
    final key = _keyOfUri(uri, roots, multiRootPrefix);
    if (key == null) continue;
    for (final spelling in _spellings(uri, key)) {
      keyOfSpelling.putIfAbsent(spelling, () => key);
    }
  }
  final failing = <String, String>{};
  var outside = false;
  var located = 0;
  for (final match in _errorLine.allMatches(output)) {
    located++;
    final key = _lookup(keyOfSpelling, match.group(1)!, multiRootPrefix);
    if (key == null) {
      outside = true;
      continue;
    }
    failing.putIfAbsent(key, () => match.group(4)!);
  }
  final errorLines = output
      .split('\n')
      .where((line) => line.startsWith('Error: ') || line.contains(': Error: '))
      .length;
  return _Verdict(
    failing: failing,
    outside: outside,
    unattributed: located == 0 || errorLines != located,
  );
}

final _isolatedRootPrefix = RegExp(r'^(?:.*/)?\.isolated_root/');

/// The key of the first spelling of `path` that `spellings` knows.
String? _lookup(
  Map<String, String> spellings,
  String path,
  String multiRootPrefix,
) {
  final slashPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  for (final spelling in [
    path,
    slashPath,
    _stripPrefix(path, multiRootPrefix),
    _stripPrefix(slashPath, multiRootPrefix),
    slashPath.replaceFirst(_bazelOutPrefix, ''),
    slashPath.replaceFirst(_isolatedRootPrefix, ''),
  ]) {
    if (spelling == null) continue;
    final key = spellings[spelling];
    if (key != null) return key;
  }
  return null;
}

/// Every name a diagnostic might use for a source: its key, and its URI.
Iterable<String> _spellings(String uri, String key) sync* {
  yield key;
  yield uri;
}

/// Normalized path spellings for an input path or `--input-source` flag value.
Iterable<String> _inputSpellings(
  String? raw, [
  List<String> multiRoots = const [],
]) sync* {
  if (raw == null || raw.isEmpty) return;
  final norm = _normalize(raw);
  if (norm.isNotEmpty) yield norm;
  if (raw.startsWith('bazel-out/') || raw.startsWith('./bazel-out/')) {
    final stripped = _normalize(raw.replaceFirst(_bazelOutPrefix, ''));
    if (stripped.isNotEmpty && stripped != norm) yield stripped;
  }
  final rawSlash = _filePathOf(raw).replaceAll(r'\', '/');
  for (final r in multiRoots) {
    final rootFile = _filePathOf(r)
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    if (rootFile.isEmpty || rootFile == '.') continue;
    if (rawSlash.startsWith('$rootFile/')) {
      final stripped = _normalize(rawSlash.substring(rootFile.length + 1));
      if (stripped.isNotEmpty && stripped != norm) yield stripped;
    }
    final normRoot = _normalize(rootFile);
    if (normRoot.isNotEmpty &&
        normRoot != '.' &&
        norm.startsWith('$normRoot/')) {
      final stripped = _normalize(norm.substring(normRoot.length + 1));
      if (stripped.isNotEmpty && stripped != norm) yield stripped;
    }
  }
}

/// The path after `multiRootPrefix`, or null for any other URI.
String? _stripPrefix(String uri, String multiRootPrefix) {
  if (uri.startsWith(multiRootPrefix)) {
    return uri.substring(multiRootPrefix.length);
  }
  return null;
}

/// The key of a source or a library: the path it has under the multi-root
/// directories, without the scheme. Null for a URI this module cannot name, such as
/// a `dart:` library or a `package:` whose package it does not list.
String? _keyOfUri(
  String uri,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  final stripped = _stripPrefix(uri, multiRootPrefix);
  if (stripped != null) return _normalize(stripped);
  if (!uri.startsWith('package:')) return null;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0) return null;
  final root = roots[rest.substring(0, slash)];
  if (root == null) return null;
  return _normalize(
    '${root.path}${root.packageUri}${rest.substring(slash + 1)}',
  );
}

/// The key a URI in a file named `fromKey` refers to, or null when the URI is not
/// one this module can name.
String? _resolveUri(
  String uri,
  String fromKey,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix,
) {
  if (uri.startsWith('package:') || uri.startsWith(multiRootPrefix)) {
    return _keyOfUri(uri, roots, multiRootPrefix);
  }
  if (uri.contains(':')) return null;
  final slash = fromKey.lastIndexOf('/');
  final dir = slash < 0 ? '' : fromKey.substring(0, slash + 1);
  return _normalize('$dir$uri');
}

/// `path` without empty and `.` segments, with each `..` applied.
String _normalize(String path) {
  if (_isNormalizedRelative(path)) return path;
  final slashPath = path.contains(r'\') ? path.replaceAll(r'\', '/') : path;
  final parts = <String>[];
  for (final part in slashPath.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

/// Reads the files of a module's sources from the multi-root directories.
///
/// Only files declared via `--source`, `--input-source`, or a dependency
/// `.koutline`'s staged excluded sources (and present in `WorkRequest.inputs`
/// when running as a persistent worker) may be read.
class _Files {
  _Files(
    this._roots, {
    required Set<String> declaredKeys,
    Set<String> declaredRootPaths = const {},
    Map<String, String> stagedRoots = const {},
    Set<String>? workerInputPaths,
  }) : _declaredKeys = declaredKeys,
       _declaredRootPaths = declaredRootPaths,
       _stagedRoots = stagedRoots,
       _workerInputPaths = workerInputPaths;

  final List<String> _roots;
  final Set<String> _declaredKeys;
  final Set<String> _declaredRootPaths;
  final Map<String, String> _stagedRoots;
  final Set<String>? _workerInputPaths;
  final String _cwd = Directory.current.path.replaceAll(r'\', '/');
  final Map<String, String?> _cache = {};
  final Map<String, ScanResult?> _scanCache = {};

  bool _matchesPathSet(Set<String> pathSet, String root, String key) {
    final rootFile = _filePathOf(root);
    final normRoot = rootFile.contains(r'\')
        ? rootFile.replaceAll(r'\', '/')
        : rootFile;
    final raw = normRoot == '.' ? key : '$normRoot/$key';
    if (pathSet.contains(raw)) return true;
    final norm = _normalize(raw);
    if (pathSet.contains(norm)) return true;
    if (raw.startsWith('/') || isWindowsDrivePath(raw)) {
      if (raw.startsWith('$_cwd/')) {
        final rel = _normalize(raw.substring(_cwd.length + 1));
        if (pathSet.contains(rel)) return true;
      }
      final normFile = _normalizeFilePath(raw);
      if (pathSet.contains(normFile)) return true;
      if (normFile.startsWith('$_cwd/')) {
        final rel = _normalize(normFile.substring(_cwd.length + 1));
        if (pathSet.contains(rel)) return true;
      }
    } else {
      final abs = '$_cwd/$norm';
      if (pathSet.contains(abs) ||
          pathSet.contains(_normalize(abs)) ||
          pathSet.contains(_normalizeFilePath(abs))) {
        return true;
      }
    }
    return false;
  }

  /// Whether `(root, key)` was explicitly named in `WorkRequest.inputs` or
  /// `--input-source`.
  bool isExplicitlyDeclaredInRoot(String root, String key) {
    final workerPaths = _workerInputPaths;
    if (workerPaths != null) {
      return _matchesPathSet(workerPaths, root, key);
    }
    if (_declaredRootPaths.isNotEmpty) {
      return _matchesPathSet(_declaredRootPaths, root, key);
    }
    return false;
  }

  /// Whether `key` may be read from `root`.
  bool isDeclaredInRoot(String root, String key) {
    if (!_declaredKeys.contains(key)) return false;
    final workerPaths = _workerInputPaths;
    if (workerPaths != null) {
      return _matchesPathSet(workerPaths, root, key);
    }
    if (_declaredRootPaths.isNotEmpty) {
      var anyRootDeclared = false;
      for (final candidateRoot in _roots) {
        if (_matchesPathSet(_declaredRootPaths, candidateRoot, key)) {
          anyRootDeclared = true;
          break;
        }
      }
      if (anyRootDeclared) {
        return _matchesPathSet(_declaredRootPaths, root, key);
      }
    }
    return true;
  }

  /// Whether `key` is declared via `--source` or `--input-source` (and present
  /// in `WorkRequest.inputs` when active).
  bool isDeclaredInRoots(String key) {
    if (!_declaredKeys.contains(key)) return false;
    for (final root in _roots) {
      if (isDeclaredInRoot(root, key)) return true;
    }
    return false;
  }

  /// Whether `key` is a declared input of this action.
  bool isDeclared(String key) =>
      isDeclaredInRoots(key) || _stagedRoots.containsKey(key);

  /// All keys declared as inputs of this action.
  Set<String> get declaredKeys => {
    for (final key in _declaredKeys)
      if (isDeclaredInRoots(key)) key,
    ..._stagedRoots.keys,
  };

  /// The single root from which [key] is declared to be read, or `null` when
  /// [key] is not a declared input of this action.
  ///
  /// When [key] is declared in [_roots], only [_roots] are considered (never
  /// [_stagedRoots]); otherwise [_stagedRoots] is used.
  String? declaredRootOf(String key) {
    if (isDeclaredInRoots(key)) {
      String? firstDeclared;
      for (final root in _roots) {
        if (!isDeclaredInRoot(root, key)) continue;
        firstDeclared ??= root;
        final path = _filePathOf(root == '.' ? key : '$root/$key');
        if (File(path).existsSync()) {
          return root;
        }
      }
      return firstDeclared;
    }
    return _stagedRoots[key];
  }

  /// The file-system path of the single declared origin for [key], or `null`
  /// when [key] is not a declared input.
  String? declaredOriginOf(String key) {
    final root = declaredRootOf(key);
    if (root == null) return null;
    return _filePathOf(root == '.' ? key : '$root/$key');
  }

  /// The text of the file with `key` from its single declared origin, or null
  /// when it is not a declared input or its declared origin does not exist.
  Future<String?> read(String key) async {
    if (!isDeclared(key)) return null;
    if (_cache.containsKey(key)) return _cache[key];
    String? text;
    final origin = declaredOriginOf(key);
    if (origin != null) {
      final file = File(origin);
      if (await file.exists()) {
        text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      }
    }
    return _cache[key] = text;
  }

  /// Cached directive scan of `key`.
  Future<ScanResult?> scan(String key, Set<String> vm) async {
    if (_scanCache.containsKey(key)) return _scanCache[key];
    final text = await read(key);
    final result = text == null ? null : scanDirectives(text, vm);
    return _scanCache[key] = result;
  }
}

/// Replaces all `--multi-root` flags in [base] with a single `--multi-root`
/// pointing at [singleRoot].
List<String> _baseWithSingleMultiRoot(List<String> base, String singleRoot) {
  final out = <String>[];
  var inserted = false;
  for (var i = 0; i < base.length; i++) {
    final arg = base[i];
    if (arg == _multiRootFlag && i + 1 < base.length) {
      i++;
      if (!inserted) {
        inserted = true;
        out
          ..add(_multiRootFlag)
          ..add(singleRoot);
      }
    } else if (arg.startsWith('$_multiRootFlag=')) {
      if (!inserted) {
        inserted = true;
        out.add('$_multiRootFlag=$singleRoot');
      }
    } else {
      out.add(arg);
    }
  }
  if (!inserted) {
    out
      ..add(_multiRootFlag)
      ..add(singleRoot);
  }
  return out;
}

/// Whether `compileModule` should stage an isolated `--multi-root` directory
/// containing only declared inputs at their single declared origins so
/// `kernel_worker`'s `MultiRootFileSystem` cannot see any undeclared or
/// shadowing files on disk.
Future<bool> _needsIsolatedMultiRoot(
  ModuleCompiler compiler,
  List<String> multiRoots,
  Iterable<String> extraMultiRoots,
  Iterable<String> keys,
  _Files files,
  Set<String> vm,
) async {
  final candidateRoots = <String>{
    ...(multiRoots.isEmpty ? const ['.'] : multiRoots),
    ...extraMultiRoots,
  };
  // Staging can be skipped only when every declared input already lives under
  // one of the declared roots (so the front end can resolve it without a
  // staged copy) and no undeclared file shadows it. Persistent workers still
  // get per-request isolation whenever staging is needed.
  for (final key in files.declaredKeys) {
    final origin = files.declaredOriginOf(key);
    if (origin == null) return true;
    final originNorm = origin.replaceAll(r'\\', '/');
    var underRoot = false;
    for (final root in candidateRoots) {
      final slashRoot = root
          .replaceAll(r'\\', '/')
          .replaceFirst(RegExp(r'/+$'), '');
      final prefix = slashRoot == '.' ? '' : '$slashRoot/';
      if (slashRoot == '.' && !originNorm.startsWith('/')) {
        // relative origin under cwd root
        underRoot = true;
        break;
      }
      if (prefix.isNotEmpty && originNorm.startsWith(prefix)) {
        underRoot = true;
        break;
      }
    }
    if (!underRoot) return true;
  }
  final checkKeys = <String>{...keys, ...files.declaredKeys};
  for (final key in checkKeys) {
    final declaredRoot = files.declaredRootOf(key);
    for (final root in candidateRoots) {
      if (root == declaredRoot) continue;
      final path = _filePathOf(root == '.' ? key : '$root/$key');
      if (File(path).existsSync()) {
        return true;
      }
    }
  }
  for (final key in keys) {
    if (await files.scan(key, vm) == null) {
      return true;
    }
  }
  return false;
}

/// Stages `$output/.isolated_root` containing only the declared inputs in
/// [files], each copied from its single [files.declaredOriginOf].
Future<({String rootDir, List<Uint8List> inputs})> _stageIsolatedMultiRoot(
  String output,
  _Files files,
  Map<String, Uint8List>? inputDigests, {
  required bool includeInputDigests,
}) async {
  final rootDir = '$output/.isolated_root';
  final dir = Directory(_filePathOf(rootDir));
  if (await dir.exists()) {
    await dir.delete(recursive: true);
  }
  await dir.create(recursive: true);
  final stagedInputs = <Uint8List>[];
  final sortedKeys = files.declaredKeys.toList()..sort();
  for (final key in sortedKeys) {
    final origin = files.declaredOriginOf(key);
    if (origin == null) continue;
    final srcFile = File(origin);
    if (!await srcFile.exists()) continue;
    final bytes = await srcFile.readAsBytes();
    final dstPath = '$rootDir/$key';
    final dstFile = File(_filePathOf(dstPath));
    await dstFile.parent.create(recursive: true);
    await dstFile.writeAsBytes(bytes);
    if (includeInputDigests) {
      final digest = _lookupDigest(origin, inputDigests) ?? sha256Of(bytes);
      stagedInputs.add(_encodeInput(kernelWorkerUri(dstPath), digest));
    }
  }
  return (rootDir: rootDir, inputs: stagedInputs);
}

/// The excluded files the sidecars list, by key. Each maps to its `package:` URI
/// when a sidecar gives one, and otherwise to its multi-root URI.
Future<Map<String, String>> _readExcluded(
  List<String> paths,
  Map<String, _PackageRoot> roots,
  String multiRootPrefix, {
  KernelModuleCache? cache,
  Map<String, Uint8List>? inputDigests,
}) async {
  final out = <String, String>{};
  for (final path in paths) {
    final Iterable<String> uris;
    if (cache != null) {
      uris = await cache.excludedLinesOf(path, inputDigests);
    } else {
      final list = <String>[];
      for (final line in await File(path).readAsLines()) {
        if (line.isEmpty || line.startsWith('#')) continue;
        list.add(line.split('\t').first);
      }
      uris = list;
    }
    for (final uri in uris) {
      final key = _keyOfUri(uri, roots, multiRootPrefix);
      if (key == null) continue;
      final known = out[key];
      if (known == null ||
          (uri.startsWith('package:') && !known.startsWith('package:'))) {
        out[key] = uri;
      }
    }
  }
  return out;
}

/// The libraries of `platform` in a `libraries.json`, plus `extraLibraries`, by bare
/// name. The platform's `include`s count too (`vm` inherits `vm_common`), and a
/// platform other than `vm` also inherits `vm` when `libraries.json` defines it.
Set<String> vmLibraries(
  Map<String, dynamic> json, {
  String platform = 'vm',
  Iterable<String> extraLibraries = const [],
}) {
  final names = <String>{};
  final seen = <String>{};
  void collect(String target) {
    if (!seen.add(target)) return;
    final entry = json[target];
    if (entry is! Map) return;
    final libraries = entry['libraries'];
    if (libraries is Map) {
      libraries.forEach((name, spec) {
        if (spec is Map && spec['supported'] == false) return;
        final text = name.toString();
        final bare = text.startsWith('dart:')
            ? text.substring('dart:'.length)
            : text;
        if (bare.startsWith('_')) return;
        names.add(bare);
      });
    }
    final includes = entry['include'];
    if (includes is List) {
      for (final include in includes) {
        if (include is Map && include['target'] is String) {
          collect(include['target'] as String);
        }
      }
    }
  }

  if (json.containsKey(platform)) {
    collect(platform);
  }
  if (platform != 'vm' && json.containsKey('vm')) {
    collect('vm');
  }
  for (final extra in extraLibraries) {
    names.add(
      extra.startsWith('dart:') ? extra.substring('dart:'.length) : extra,
    );
  }
  return names;
}

/// One URI-bearing directive of a source's prologue.
class ScanRef {
  const ScanRef(this.kind, this.uri);

  /// `import`, `export`, `part` or `part of`.
  final String kind;

  /// The URI. A configurable import gives the alternative it takes for the VM.
  final String uri;

  bool get isPart => kind == 'part';

  bool get isPartOf => kind == 'part of';
}

/// The directives of a source's prologue.
class ScanResult {
  const ScanResult(this.refs, {this.libraryName, this.partOfLibrary});

  final List<ScanRef> refs;

  /// The name from `library <name>;`, when declared.
  final String? libraryName;

  /// The library name from `part of <name>;`, when a part names its library by
  /// identifier rather than URI.
  final String? partOfLibrary;
}

/// The directives in the prologue of a Dart source, or null when the prologue has a
/// form this scanner does not read.
ScanResult? scanDirectives(String source, Set<String> vmLibraries) {
  try {
    return _Prologue(_Lexer(source), vmLibraries).parse();
  } on _Unparsable {
    return null;
  }
}

class _Unparsable implements Exception {
  const _Unparsable();
}

const _identKind = 0;
const _stringKind = 1;
const _punctKind = 2;
const _otherKind = 3;

class _Token {
  const _Token(this.kind, this.text, {this.raw = false});

  final int kind;
  final String text;
  final bool raw;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x24 ||
    c >= 0x80;

bool _isIdentChar(int c) => _isIdentStart(c) || _isDigit(c);

int _skipLine(String src, int start) {
  var at = start;
  while (at < src.length && src[at] != '\n' && src[at] != '\r') {
    at++;
  }
  return at;
}

/// The index just past the block comment that starts at `start`. Dart block
/// comments nest.
int _skipBlockComment(String src, int start) {
  var depth = 0;
  var at = start;
  while (at < src.length) {
    if (src.startsWith('/*', at)) {
      depth++;
      at += 2;
    } else if (src.startsWith('*/', at)) {
      depth--;
      at += 2;
      if (depth == 0) return at;
    } else {
      at++;
    }
  }
  throw const _Unparsable();
}

String _unescape(String s) {
  if (!s.contains('\\')) return s;
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i++];
    if (ch != '\\') {
      out.write(ch);
      continue;
    }
    if (i >= s.length) throw const _Unparsable();
    final esc = s[i++];
    switch (esc) {
      case 'n':
        out.write('\n');
      case 'r':
        out.write('\r');
      case 'f':
        out.write('\f');
      case 'b':
        out.write('\b');
      case 't':
        out.write('\t');
      case 'v':
        out.write('\v');
      case 'x':
        if (i + 2 > s.length) throw const _Unparsable();
        final code = int.tryParse(s.substring(i, i + 2), radix: 16);
        if (code == null) throw const _Unparsable();
        out.writeCharCode(code);
        i += 2;
      case 'u':
        if (i < s.length && s[i] == '{') {
          final close = s.indexOf('}', i + 1);
          if (close < 0) throw const _Unparsable();
          final code = int.tryParse(s.substring(i + 1, close), radix: 16);
          if (code == null || code < 0 || code > 0x10FFFF) {
            throw const _Unparsable();
          }
          out.writeCharCode(code);
          i = close + 1;
        } else {
          if (i + 4 > s.length) throw const _Unparsable();
          final code = int.tryParse(s.substring(i, i + 4), radix: 16);
          if (code == null) throw const _Unparsable();
          out.writeCharCode(code);
          i += 4;
        }
      default:
        out.write(esc);
    }
  }
  return out.toString();
}

/// Reads the tokens of a Dart source one at a time, so a scan that stops at the end
/// of the directives never reads the rest of the file.
class _Lexer {
  _Lexer(this._src);

  final String _src;
  var _at = 0;
  _Token? _ahead;

  _Token? peek() => _ahead ??= _scan();

  _Token? take() {
    final token = peek();
    _ahead = null;
    return token;
  }

  _Token? _scan() {
    final src = _src;
    final n = src.length;
    if (_at == 0) {
      if (src.startsWith('\uFEFF')) _at++;
      if (src.startsWith('#!', _at)) {
        _at = _skipLine(src, _at + 2);
      }
    }
    while (_at < n) {
      final ch = src[_at];
      if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
        _at++;
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '/') {
        _at = _skipLine(src, _at + 2);
        continue;
      }
      if (ch == '/' && _at + 1 < n && src[_at + 1] == '*') {
        _at = _skipBlockComment(src, _at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        final word = src.substring(start, _at);
        if (word == 'r' && _at < n && (src[_at] == "'" || src[_at] == '"')) {
          return _string(raw: true);
        }
        return _Token(_identKind, word);
      }
      if (_isDigit(code)) {
        final start = _at;
        while (_at < n && _isIdentChar(src.codeUnitAt(_at))) {
          _at++;
        }
        return _Token(_otherKind, src.substring(start, _at));
      }
      if (ch == "'" || ch == '"') return _string(raw: false);
      _at++;
      return _Token(_punctKind, ch);
    }
    return null;
  }

  /// The string literal at `_at`, with its quotes removed and its escapes kept.
  _Token _string({required bool raw}) {
    final src = _src;
    final quote = src[_at];
    final triple = src.startsWith(quote * 3, _at);
    final delim = triple ? quote * 3 : quote;
    var contentStart = _at + delim.length;
    final endQuote = _skipString(_at, raw: raw);
    final contentEnd = endQuote - delim.length;
    if (triple && contentStart < contentEnd) {
      if (src.startsWith('\r\n', contentStart)) {
        contentStart += 2;
      } else if (src[contentStart] == '\n' || src[contentStart] == '\r') {
        contentStart += 1;
      }
    }
    _at = endQuote;
    return _Token(
      _stringKind,
      src.substring(contentStart, contentEnd),
      raw: raw,
    );
  }

  /// The index just past the string literal that starts at `quoteAt`.
  int _skipString(int quoteAt, {required bool raw}) {
    final src = _src;
    final n = src.length;
    final quote = src[quoteAt];
    final triple = src.startsWith(quote * 3, quoteAt);
    final delim = triple ? quote * 3 : quote;
    var at = quoteAt + delim.length;
    while (true) {
      if (at >= n) throw const _Unparsable();
      if (!raw && src[at] == '\\') {
        if (at + 1 >= n) throw const _Unparsable();
        at += 2;
        continue;
      }
      if (!raw && src.startsWith(r'${', at)) {
        at = _skipInterpolation(at + 2);
        continue;
      }
      if (src.startsWith(delim, at)) {
        return at + delim.length;
      }
      if (!triple && (src[at] == '\n' || src[at] == '\r')) {
        throw const _Unparsable();
      }
      at++;
    }
  }

  /// The index just past the `}` that closes a `${...}` string interpolation
  /// whose body starts at `start`.
  int _skipInterpolation(int start) {
    final src = _src;
    final n = src.length;
    var at = start;
    var depth = 1;
    while (at < n) {
      final ch = src[at];
      if (ch == '/' && at + 1 < n && src[at + 1] == '/') {
        at = _skipLine(src, at + 2);
        continue;
      }
      if (ch == '/' && at + 1 < n && src[at + 1] == '*') {
        at = _skipBlockComment(src, at);
        continue;
      }
      final code = ch.codeUnitAt(0);
      if (_isIdentStart(code) || _isDigit(code)) {
        final wordStart = at;
        while (at < n && _isIdentChar(src.codeUnitAt(at))) {
          at++;
        }
        if (at - wordStart == 1 &&
            src[wordStart] == 'r' &&
            at < n &&
            (src[at] == "'" || src[at] == '"')) {
          at = _skipString(at, raw: true);
        }
        continue;
      }
      if (ch == "'" || ch == '"') {
        at = _skipString(at, raw: false);
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) return at + 1;
      }
      at++;
    }
    throw const _Unparsable();
  }
}

/// Reads the directive prologue: `library`, `import`, `export`, `part` and `part
/// of`, with the annotations before them. The first other token ends it.
class _Prologue {
  _Prologue(this._lexer, this._vm);

  final _Lexer _lexer;
  final Set<String> _vm;

  _Token? _peek() => _lexer.peek();

  _Token _take() {
    final token = _lexer.take();
    if (token == null) throw const _Unparsable();
    return token;
  }

  bool _is(String text, int kind) {
    final token = _peek();
    return token != null && token.kind == kind && token.text == text;
  }

  bool _ident(String text) => _is(text, _identKind);

  bool _punct(String text) => _is(text, _punctKind);

  void _expect(String text) {
    if (!_punct(text)) throw const _Unparsable();
    _lexer.take();
  }

  /// Consumes up to and including `text`.
  void _skipPast(String text) {
    while (!_punct(text)) {
      _take();
    }
    _lexer.take();
  }

  void _identToken() {
    if (_take().kind != _identKind) throw const _Unparsable();
  }

  /// A dotted identifier such as `foo` or `foo.bar.baz`.
  String _dottedIdent() {
    final first = _take();
    if (first.kind != _identKind) throw const _Unparsable();
    final out = StringBuffer(first.text);
    while (_punct('.')) {
      _lexer.take();
      final next = _take();
      if (next.kind != _identKind) throw const _Unparsable();
      out
        ..write('.')
        ..write(next.text);
    }
    return out.toString();
  }

  /// Adjacent string literals are one URI.
  String _string() {
    final token = _take();
    if (token.kind != _stringKind) throw const _Unparsable();
    final out = StringBuffer(token.raw ? token.text : _unescape(token.text));
    while (_peek()?.kind == _stringKind) {
      final next = _take();
      out.write(next.raw ? next.text : _unescape(next.text));
    }
    return out.toString();
  }

  /// `@name`, `@name.name`, `@name<...>(...)`, or `@name<...>.name(...)`.
  void _annotation() {
    _expect('@');
    _identToken();
    while (_punct('.')) {
      _lexer.take();
      _identToken();
    }
    if (_punct('<')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '<') depth++;
        if (token.kind == _punctKind && token.text == '>') depth--;
      } while (depth > 0);
      while (_punct('.')) {
        _lexer.take();
        _identToken();
      }
    }
    if (_punct('(')) {
      var depth = 0;
      do {
        final token = _take();
        if (token.kind == _punctKind && token.text == '(') depth++;
        if (token.kind == _punctKind && token.text == ')') depth--;
      } while (depth > 0);
    }
  }

  /// The `if (...)` test of a configurable import, after its `(`, through its `)`.
  /// True when it holds for the VM. In CFE's configurable-import environment,
  /// available SDK libraries are mapped to `'true'` and all other names are
  /// unspecified (matching only `== ''`).
  bool _condition() {
    final text = _dottedIdent();
    String? value;
    if (_punct('=')) {
      _lexer.take();
      _expect('=');
      value = _string();
    }
    _expect(')');
    const prefix = 'dart.library.';
    if (text.startsWith(prefix)) {
      final present = _vm.contains(text.substring(prefix.length));
      if (!present) return false;
      return value == null || value == 'true';
    }
    return value == '';
  }

  /// `import` or `export` after its keyword: the URI, then any `if`
  /// alternatives, then the rest of the directive, which names nothing to read.
  ScanRef _uriDirective(String kind) {
    final declared = _string();
    var chosen = declared;
    var picked = false;
    while (_ident('if')) {
      _lexer.take();
      _expect('(');
      final holds = _condition();
      final alternative = _string();
      if (holds && !picked) {
        chosen = alternative;
        picked = true;
      }
    }
    _skipPast(';');
    return ScanRef(kind, chosen);
  }

  ScanResult parse() {
    final refs = <ScanRef>[];
    String? libraryName;
    String? partOfLibrary;
    while (true) {
      final token = _peek();
      if (token == null) break;
      if (token.kind == _punctKind && token.text == '@') {
        _annotation();
        continue;
      }
      if (token.kind != _identKind) break;
      if (token.text == 'library') {
        _lexer.take();
        if (_punct(';')) {
          _lexer.take();
        } else if (_peek()?.kind == _identKind) {
          libraryName ??= _dottedIdent();
          _expect(';');
        } else {
          break;
        }
      } else if (token.text == 'import' || token.text == 'export') {
        _lexer.take();
        if (_peek()?.kind != _stringKind) break;
        refs.add(_uriDirective(token.text));
      } else if (token.text == 'part') {
        _lexer.take();
        if (_ident('of')) {
          _lexer.take();
          if (_peek()?.kind == _stringKind) {
            refs.add(ScanRef('part of', _string()));
          } else {
            partOfLibrary ??= _dottedIdent();
          }
          _expect(';');
        } else if (_peek()?.kind == _stringKind) {
          refs.add(ScanRef('part', _string()));
          _expect(';');
        } else {
          break;
        }
      } else {
        break;
      }
    }
    return ScanResult(
      refs,
      libraryName: libraryName,
      partOfLibrary: partOfLibrary,
    );
  }
}

/// Each package's root, read from the `package_config.json` the module compiles
/// against, so a `package:` source can be matched to the path a diagnostic names.
Future<Map<String, _PackageRoot>> _packageRoots(
  String packagesFile,
  String multiRootPrefix,
) async {
  final config =
      jsonDecode(await File(_filePathOf(packagesFile)).readAsString()) as Map;
  final roots = <String, _PackageRoot>{};
  for (final entry in (config['packages'] as List).cast<Map>()) {
    var root = entry['rootUri'] as String;
    if (root.startsWith(multiRootPrefix)) {
      root = root.substring(multiRootPrefix.length);
    }
    if (root.isNotEmpty && !root.endsWith('/')) root = '$root/';
    final packageUri = (entry['packageUri'] as String?) ?? 'lib/';
    roots[entry['name'] as String] = _PackageRoot(root, packageUri);
  }
  return roots;
}

class _PackageRoot {
  const _PackageRoot(this.path, this.packageUri);

  /// The `rootUri` with its scheme removed, ending in `/` unless empty.
  final String path;

  /// The `packageUri`, ending in `/`.
  final String packageUri;
}

/// Expands `@params` arguments in one-shot mode, one argument per line.
Future<List<String>> _expandParamFiles(List<String> args) async {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@') && File(arg.substring(1)).existsSync()) {
      final lines = await File(arg.substring(1)).readAsLines();
      out.addAll(lines);
    } else {
      out.add(arg);
    }
  }
  return out;
}

/// The result of one `kernel_worker` run.
class ModuleOutcome {
  const ModuleOutcome(this.exitCode, this.output);

  final int exitCode;
  final String output;
}

/// Runs `kernel_worker` with a full argument list. `inputs` are the Bazel
/// `WorkRequest.inputs` of the request. They are passed on unchanged, so the child
/// receives the request Bazel would have sent it.
abstract class ModuleCompiler {
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs);

  Future<void> close();
}

/// One `kernel_worker` process per compile.
class _OneShot implements ModuleCompiler {
  _OneShot(this._dartaotruntime, this._kernelWorker);

  final String _dartaotruntime;
  final String _kernelWorker;

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    final result = await Process.run(_dartaotruntime, [
      patchSnapshotSplitCommas(_kernelWorker),
      ...kernelWorkerArgs(args),
    ]);
    return ModuleOutcome(result.exitCode, '${result.stdout}${result.stderr}');
  }

  @override
  Future<void> close() async {}
}

/// One `kernel_worker` child, kept running across requests.
///
/// A child that cannot be trusted is killed and replaced, and its request is sent
/// once more to the new child. That is after the child dies; after a request that runs
/// past the timeout, which a wedged child does; after bytes that are not the
/// `WorkResponse` to the request; and after a crash, since the child then never answers
/// its next request. A compile writes only its own outputs, so repeating it is safe.
/// A request that fails again on the new child fails the action with both reasons.
class _Persistent implements ModuleCompiler {
  _Persistent(
    this._dartaotruntime,
    this._kernelWorker, {
    Duration? requestTimeout,
  }) : _requestTimeout = requestTimeout ?? _defaultRequestTimeout;

  /// Far above the compile of one library. A request that takes longer is wedged.
  /// `--request-timeout-seconds` replaces it, so a test can exercise a wedged child
  /// without waiting this long.
  static const _defaultRequestTimeout = Duration(minutes: 15);

  /// What the compiler prints for a crash.
  static const _crashMarker = 'Crash when compiling';

  final String _dartaotruntime;
  final String _kernelWorker;
  final Duration _requestTimeout;
  Process? _child;
  _Frames? _responses;

  /// The `request_id` of every request. Bazel sends a worker that is not multiplexed
  /// request 0, and `kernel_worker` answers with the id it was sent.
  static const _requestId = 0;

  /// The child's stderr, kept for the failure message of a child that dies.
  final _stderr = StringBuffer();

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    // Digested before the child is written to, so a file that cannot be read fails the
    // request with its reason, not as a child that died.
    final workerArgs = kernelWorkerArgs(args);
    final withDigests = await _withDigests(workerArgs, inputs);
    final first = await _attempt(workerArgs, withDigests);
    if (!first.lost) return first.outcome;
    final second = await _attempt(workerArgs, withDigests);
    if (second.lost) {
      return ModuleOutcome(
        second.outcome.exitCode,
        'Failed twice, on a fresh kernel_worker each time.\n'
        'First attempt: ${first.outcome.output}\nSecond attempt: '
        '${second.outcome.output}',
      );
    }
    return second.outcome;
  }

  /// Sends one request to the running child, or to a new one, and reads its answer.
  Future<_Attempt> _attempt(List<String> args, List<Uint8List> inputs) async {
    final child = await _start();
    try {
      child.stdin.add(_frame(_encodeRequest(args, inputs, _requestId)));
      await child.stdin.flush();
    } on Object {
      // A child that died before reading the request: the read below reports it.
    }
    try {
      final frame = await _responses!.next().timeout(_requestTimeout);
      if (frame == null) {
        await _reap();
        return _Attempt(
          ModuleOutcome(1, 'kernel_worker exited before responding.\n$_stderr'),
          lost: true,
        );
      }
      final response = _WorkResponse.decode(frame);
      if (response.requestId != _requestId) {
        throw FormatException(
          'it answered request ${response.requestId}, not request $_requestId',
        );
      }
      final outcome = ModuleOutcome(response.exitCode, response.output);
      final crashed =
          outcome.exitCode != 0 && outcome.output.contains(_crashMarker);
      if (crashed) await _reap();
      return _Attempt(outcome, lost: crashed);
    } on TimeoutException {
      await _reap();
      return _Attempt(
        ModuleOutcome(
          1,
          'kernel_worker did not answer within $_requestTimeout, so it was '
          'killed.\n$_stderr',
        ),
        lost: true,
      );
    } catch (error) {
      await _reap();
      return _Attempt(
        ModuleOutcome(
          1,
          'kernel_worker sent bytes that are not a WorkResponse ($error), so it was '
          'killed.\n$_stderr',
        ),
        lost: true,
      );
    }
  }

  Future<Process> _start() async {
    final running = _child;
    if (running != null) return running;
    final child = await Process.start(_dartaotruntime, [
      patchSnapshotSplitCommas(_kernelWorker),
      _persistentFlag,
    ]);
    _stderr.clear();
    child.stderr.transform(utf8.decoder).listen(_stderr.write);
    _child = child;
    _responses = _Frames(child.stdout);
    return child;
  }

  /// Kills the child and waits for it to exit. The kill is SIGKILL: a stopped child
  /// does not act on SIGTERM until it is continued, so waiting after SIGTERM could wait
  /// forever.
  Future<void> _reap() async {
    final child = _child;
    _child = null;
    if (child == null) return;
    child.kill(ProcessSignal.sigkill);
    unawaited(child.stdin.close().catchError((Object _) {}));
    await child.exitCode;
  }

  @override
  Future<void> close() => _reap();
}

/// One attempt at a request. `lost` is set when the child died, wedged, or answered
/// with bytes that are not the answer, or crashed, so the request is repeated.
class _Attempt {
  _Attempt(this.outcome, {required this.lost});

  final ModuleOutcome outcome;
  final bool lost;
}

/// The startup flag that sets the request timeout, in seconds. A test passes it with
/// `--worker_extra_flag=DartKernel=--request-timeout-seconds=N`.
const _requestTimeoutFlag = '--request-timeout-seconds=';

// ---------------------------------------------------------------------------
// Digests. Bazel 9.3.0 expands tree artifacts (`declare_directory`, such as
// `.kmod` and `.koutline` directories) in `WorkRequest.inputs` into individual
// `Input` entries with SHA-256 digests for every constituent file (`<dir>/0.dill`,
// `<dir>/index.json`, `<dir>/sources/<key>`). Those digests are forwarded
// directly to `kernel_worker` without re-hashing from disk.
//
// Only files that lack a non-empty digest in `WorkRequest.inputs` — such as
// intra-module SCC kernels produced earlier in the same `compileModule` run
// (which are hashed once in memory when needed) or files in synthetic test
// requests that omit `WorkRequest.inputs` digests — are hashed with `sha256Of`.

/// The SHA-256 digest of the file at `path`.
Future<Uint8List> _digestOf(String path) async =>
    sha256Of(await File(_filePathOf(path)).readAsBytes());

/// The SHA-256 digest of `message`, as 32 bytes.
Uint8List sha256Of(Uint8List message) {
  final h = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  // The message, a 0x80 byte, zeros, and its bit length as 64 bits, to a whole block.
  final paddedLength = ((message.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength)..setRange(0, message.length, message);
  padded[message.length] = 0x80;
  final bits = message.length * 8;
  final view = ByteData.sublistView(padded);
  view.setUint32(paddedLength - 8, bits ~/ 0x100000000);
  view.setUint32(paddedLength - 4, bits & 0xffffffff);

  final w = List<int>.filled(64, 0);
  for (var block = 0; block < paddedLength; block += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(block + i * 4);
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (hh + s1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, h[i]);
  }
  return out.buffer.asUint8List();
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

const _sha256K = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// The `Input` message for a file: its `path` and `digest`.
Uint8List _encodeInput(String path, Uint8List digest) {
  final writer = _Writer()
    ..stringField(1, path)
    ..messageField(2, digest);
  return writer.toBytes();
}

/// Decodes the `path` (field 1) and `digest` (field 2) of a protobuf `Input`
/// message, copying `digest` out of `bytes` so the message buffer is not pinned.
({String path, Uint8List digest}) _decodeInput(Uint8List bytes) {
  final reader = _Reader(bytes);
  var path = '';
  var digest = Uint8List(0);
  while (!reader.done) {
    final key = reader.varint();
    final field = key >> 3;
    final wire = key & 7;
    if (field == 1 && wire == 2) {
      path = utf8.decode(reader.bytes(), allowMalformed: true);
    } else if (field == 2 && wire == 2) {
      digest = Uint8List.fromList(reader.bytes());
    } else {
      reader.skip(wire);
    }
  }
  return (path: path, digest: digest);
}

/// Decodes `path` and a view of `digest` from a single `Input` message without
/// allocating a new `Uint8List` copy for the digest.
({String path, Uint8List digest}) _decodeInputView(Uint8List bytes) {
  final reader = _Reader(bytes);
  var path = '';
  var digest = _emptyBytes;
  while (!reader.done) {
    final key = reader.varint();
    final field = key >> 3;
    final wire = key & 7;
    if (field == 1 && wire == 2) {
      path = utf8.decode(reader.bytes(), allowMalformed: true);
    } else if (field == 2 && wire == 2) {
      digest = reader.bytes();
    } else {
      reader.skip(wire);
    }
  }
  return (path: path, digest: digest);
}

final Uint8List _emptyBytes = Uint8List(0);

/// Public wrapper around [_withDigests] for unit tests.
Future<List<Uint8List>> ensureSummaryDigests(
  List<String> args,
  List<Uint8List> inputs,
) => _withDigests(args, inputs);

/// The request's `inputs`, with a digest added for each `--input-summary` or
/// `--input-linked` file that does not already carry a non-empty digest in
/// `inputs`. If `inputs` already has a non-empty digest under a normalized
/// spelling of the path (such as `./<path>` vs `<path>`), that digest is reused
/// without reading or hashing the file from disk.
Future<List<Uint8List>> _withDigests(
  List<String> args,
  List<Uint8List> inputs,
) async {
  var hasSummaryArg = false;
  for (var i = 0; i + 1 < args.length; i++) {
    final arg = args[i];
    if (arg == '--input-summary' || arg == '--input-linked') {
      hasSummaryArg = true;
      break;
    }
  }
  if (!hasSummaryArg) return inputs;

  final exactWithDigest = <String>{};
  for (var idx = 0; idx < inputs.length; idx++) {
    final decoded = _decodeInputView(inputs[idx]);
    if (decoded.path.isNotEmpty && decoded.digest.isNotEmpty) {
      exactWithDigest.add(decoded.path);
    }
  }

  var allPresent = true;
  for (var i = 0; i + 1 < args.length; i++) {
    final arg = args[i];
    if (arg != '--input-summary' && arg != '--input-linked') continue;
    final targetPath = kernelWorkerUri(args[i + 1]);
    if (!exactWithDigest.contains(targetPath)) {
      allPresent = false;
      break;
    }
  }
  if (allPresent) return inputs;

  final emptyDigestIndices = <String, List<int>>{};
  final byPath = <String, Uint8List>{};
  for (var idx = 0; idx < inputs.length; idx++) {
    final decoded = _decodeInput(inputs[idx]);
    if (decoded.path.isEmpty) continue;
    if (decoded.digest.isNotEmpty) {
      byPath[decoded.path] = decoded.digest;
      final fileSpelling = _filePathOf(decoded.path);
      byPath.putIfAbsent(fileSpelling, () => decoded.digest);
      byPath.putIfAbsent(kernelWorkerUri(fileSpelling), () => decoded.digest);
      final norm = _normalizeFilePath(fileSpelling);
      byPath.putIfAbsent(norm, () => decoded.digest);
      byPath.putIfAbsent(kernelWorkerUri(norm), () => decoded.digest);
      final relNorm = _normalize(fileSpelling);
      if (relNorm.isNotEmpty &&
          !isWindowsDrivePath(fileSpelling) &&
          !fileSpelling.startsWith('/')) {
        byPath.putIfAbsent(relNorm, () => decoded.digest);
        byPath.putIfAbsent('./$relNorm', () => decoded.digest);
      }
    } else {
      (emptyDigestIndices[decoded.path] ??= <int>[]).add(idx);
      final uriSpelling = kernelWorkerUri(decoded.path);
      if (uriSpelling != decoded.path) {
        (emptyDigestIndices[uriSpelling] ??= <int>[]).add(idx);
      }
    }
  }
  List<Uint8List>? out;
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i] != '--input-summary' && args[i] != '--input-linked') continue;
    final rawPath = args[i + 1];
    final targetPath = kernelWorkerUri(rawPath);
    final filePath = _filePathOf(rawPath);
    if (!exactWithDigest.add(targetPath)) continue;
    final digest =
        _lookupDigest(targetPath, byPath) ??
        _lookupDigest(filePath, byPath) ??
        await _digestOf(filePath);
    byPath[targetPath] = digest;
    byPath[filePath] = digest;
    out ??= [...inputs];
    final replaceIndices =
        emptyDigestIndices.remove(targetPath) ??
        emptyDigestIndices.remove(filePath);
    if (replaceIndices != null && replaceIndices.isNotEmpty) {
      final encoded = _encodeInput(targetPath, digest);
      for (final idx in replaceIndices) {
        out[idx] = encoded;
      }
    } else {
      out.add(_encodeInput(targetPath, digest));
    }
  }
  return out ?? inputs;
}

// ---------------------------------------------------------------------------
// The Bazel worker protocol: varint-length-prefixed protobuf messages. Only the
// fields this tool reads or writes are handled, and the rest are skipped.

/// Reads varint-length-prefixed frames from a byte stream.
class _Frames {
  _Frames(Stream<List<int>> source) : _iterator = StreamIterator(source);

  final StreamIterator<List<int>> _iterator;
  Uint8List _chunk = _emptyBytes;
  int _offset = 0;

  Future<bool> _fill() async {
    while (true) {
      if (!await _iterator.moveNext()) return false;
      final current = _iterator.current;
      if (current.isEmpty) continue;
      _chunk = current is Uint8List ? current : Uint8List.fromList(current);
      _offset = 0;
      return true;
    }
  }

  Future<int?> _varint() async {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_offset >= _chunk.length && !await _fill()) return null;
      final byte = _chunk[_offset++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  /// The next frame's bytes, or null at end of stream.
  Future<Uint8List?> next() async {
    final length = await _varint();
    if (length == null) return null;
    final out = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (_offset >= _chunk.length && !await _fill()) return null;
      final available = _chunk.length - _offset;
      final need = length - written;
      final count = available < need ? available : need;
      out.setRange(written, written + count, _chunk, _offset);
      _offset += count;
      written += count;
    }
    if (_offset >= _chunk.length) {
      _chunk = _emptyBytes;
      _offset = 0;
    }
    return out;
  }
}

/// Reads one protobuf message.
class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get done => _pos >= _bytes.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = _bytes[_pos++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final length = varint();
    final out = Uint8List.sublistView(_bytes, _pos, _pos + length);
    _pos += length;
    return out;
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        bytes();
      case 5:
        _pos += 4;
      default:
        throw FormatException('Unsupported protobuf wire type $wireType.');
    }
  }
}

/// Writes one protobuf message. Zero values are omitted, as proto3 does.
class _Writer {
  final _out = BytesBuilder();

  void varintField(int field, int value) {
    if (value == 0) return;
    _addVarint(_out, field << 3);
    _addVarint(_out, value);
  }

  void stringField(int field, String value) {
    if (value.isEmpty) return;
    messageField(field, utf8.encode(value));
  }

  /// A length-delimited field: a string, or an embedded message.
  void messageField(int field, List<int> bytes) {
    _addVarint(_out, (field << 3) | 2);
    _addVarint(_out, bytes.length);
    _out.add(bytes);
  }

  Uint8List toBytes() => _out.toBytes();
}

void _addVarint(BytesBuilder out, int value) {
  var rest = value;
  while (rest >= 0x80) {
    out.addByte((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  out.addByte(rest);
}

Uint8List _frame(Uint8List message) {
  final out = BytesBuilder();
  _addVarint(out, message.length);
  out.add(message);
  return out.toBytes();
}

/// Decodes the `inputs` list from a raw `WorkRequest` protobuf payload,
/// copying each `Input` entry out of [bytes] so the request buffer is not pinned.
List<Uint8List> decodeKernelModuleWorkRequestInputs(Uint8List bytes) =>
    _WorkRequest.decode(bytes).inputs;

/// `WorkRequest`: `arguments` = 1, `inputs` = 2 (each an `Input` message, kept as
/// an unpinned copy of its bytes so it is forwarded unchanged without pinning
/// the request buffer), `request_id` = 3.
class _WorkRequest {
  _WorkRequest(this.arguments, this.inputs, this.requestId);

  factory _WorkRequest.decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    final arguments = <String>[];
    final inputs = <Uint8List>[];
    var requestId = 0;
    while (!reader.done) {
      final key = reader.varint();
      final field = key >> 3;
      final wire = key & 7;
      if (field == 1 && wire == 2) {
        arguments.add(utf8.decode(reader.bytes()));
      } else if (field == 2 && wire == 2) {
        inputs.add(Uint8List.fromList(reader.bytes()));
      } else if (field == 3 && wire == 0) {
        requestId = reader.varint();
      } else {
        reader.skip(wire);
      }
    }
    return _WorkRequest(arguments, inputs, requestId);
  }

  final List<String> arguments;
  final List<Uint8List> inputs;
  final int requestId;
}

/// The `WorkRequest` for one compile. The child answers with the same `request_id`.
Uint8List _encodeRequest(
  List<String> arguments,
  List<Uint8List> inputs,
  int requestId,
) {
  final writer = _Writer();
  for (final argument in arguments) {
    writer.stringField(1, argument);
  }
  for (final input in inputs) {
    writer.messageField(2, input);
  }
  writer.varintField(3, requestId);
  return writer.toBytes();
}

/// `WorkResponse`: `exit_code` = 1, `output` = 2, `request_id` = 3.
class _WorkResponse {
  _WorkResponse(this.exitCode, this.output, this.requestId);

  factory _WorkResponse.decode(Uint8List bytes) {
    final reader = _Reader(bytes);
    var exitCode = 0;
    var output = '';
    var requestId = 0;
    while (!reader.done) {
      final key = reader.varint();
      final field = key >> 3;
      final wire = key & 7;
      if (field == 1 && wire == 0) {
        exitCode = reader.varint();
      } else if (field == 2 && wire == 2) {
        output = utf8.decode(reader.bytes());
      } else if (field == 3 && wire == 0) {
        requestId = reader.varint();
      } else {
        reader.skip(wire);
      }
    }
    return _WorkResponse(exitCode, output, requestId);
  }

  final int exitCode;
  final String output;
  final int requestId;
}

Uint8List _encodeResponse(int exitCode, String output, int requestId) {
  final writer = _Writer()
    ..varintField(1, exitCode)
    ..stringField(2, output)
    ..varintField(3, requestId);
  return writer.toBytes();
}

/// Strips `Source.sourceCode` UTF-8 bytes from a compiled Kernel `.dill` while
/// preserving `uri`, `lineStarts`, `importUri`, and `constantCoverageConstructors`.
///
/// `kernel_worker` has no `--no-embed-sources` flag, so it embeds the full source
/// text of every `.dart` file in each module `.dill`'s `SourceTable` (~55% of all
/// `.dill` bytes). The VM uses `lineStarts` (not `sourceCode`) for stack traces and
/// `SourceReport` coverage, and downstream `--input-linked` compiles read only
/// library outlines.
///
/// Format guard: reads the 32-bit kernel format version at byte offset 4 of the
/// header and accepts only [supportedKernelFormatVersions] (version 138, Dart
/// 3.13.x). On any other format version, writes a diagnostic to [errSink]
/// (defaulting to [stderr]) and falls back to returning [data] unstripped,
/// never emitting a malformed `.dill`.
Uint8List stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) =>
    _stripSourceCodeFromDill(data, errSink: errSink);

Uint8List _stripSourceCodeFromDill(Uint8List data, {StringSink? errSink}) {
  final sink = errSink ?? stderr;
  if (data.length < 8) return data;
  final bd = ByteData.sublistView(data);
  if (bd.getUint32(0) != Tag.ComponentFile) return data;
  final version = bd.getUint32(4);
  if (!supportedKernelFormatVersions.contains(version)) {
    sink.writeln(
      'kernel_module: unsupported kernel format version $version '
      '(supported: $supportedKernelFormatVersions); '
      'falling back to unstripped dill.',
    );
    return data;
  }
  if (data.length < 48) return data;
  final lastSize = bd.getUint32(data.length - 4);
  if (lastSize == data.length) {
    return _stripSingleComponentSourceCode(data, sink);
  }
  final ranges = <(int, int)>[];
  var end = data.length;
  while (end >= 48) {
    final compSize = bd.getUint32(end - 4);
    if (compSize < 48 || compSize > end) return data;
    final start = end - compSize;
    if (bd.getUint32(start) != Tag.ComponentFile) return data;
    final compVersion = bd.getUint32(start + 4);
    if (!supportedKernelFormatVersions.contains(compVersion)) {
      sink.writeln(
        'kernel_module: unsupported kernel format version $compVersion '
        '(supported: $supportedKernelFormatVersions); '
        'falling back to unstripped dill.',
      );
      return data;
    }
    ranges.add((start, end));
    end = start;
  }
  if (end != 0 || ranges.isEmpty) return data;
  final out = BytesBuilder(copy: false);
  for (var i = ranges.length - 1; i >= 0; i--) {
    final (s, e) = ranges[i];
    out.add(
      _stripSingleComponentSourceCode(Uint8List.sublistView(data, s, e), sink),
    );
  }
  return out.takeBytes();
}

Uint8List _stripSingleComponentSourceCode(Uint8List data, StringSink sink) {
  final bd = ByteData.sublistView(data);
  final libCount = bd.getUint32(data.length - 8);
  final idxCount = libCount + 12;
  final idxBytes = idxCount * 4;
  if (idxBytes > data.length) return data;
  final rawIdxStart = data.length - idxBytes;

  final fields = List<int>.generate(
    idxCount,
    (i) => bd.getUint32(rawIdxStart + i * 4),
  );
  final offSourceTable = fields[0];
  final offConstantTable = fields[1];
  final offLinkTable = fields[3];
  final offMetadataPayloads = fields[4];
  final offMetadataMappings = fields[5];
  final offStringTable = fields[6];
  final offComponentIndex = fields[7];
  if (offSourceTable + 4 > offConstantTable ||
      offConstantTable > offLinkTable ||
      offLinkTable > offMetadataPayloads ||
      offMetadataPayloads > offMetadataMappings ||
      offMetadataMappings > offStringTable ||
      offStringTable > offComponentIndex ||
      offComponentIndex > rawIdxStart) {
    return data;
  }

  final numSources = bd.getUint32(offSourceTable);
  if (numSources == 0) return data;

  var pos = offSourceTable + 4;
  int readUInt30() {
    final b0 = data[pos++];
    if ((b0 & 0x80) == 0) return b0;
    if ((b0 & 0x40) == 0) {
      return ((b0 & 0x3f) << 8) | data[pos++];
    }
    final b1 = data[pos++];
    final b2 = data[pos++];
    final b3 = data[pos++];
    return ((b0 & 0x3f) << 24) | (b1 << 16) | (b2 << 8) | b3;
  }

  final newSt = BytesBuilder(copy: false);
  final header4 = ByteData(4)..setUint32(0, numSources);
  newSt.add(header4.buffer.asUint8List());
  final newSourceOffsets = List<int>.filled(numSources, 0);

  for (var i = 0; i < numSources; i++) {
    newSourceOffsets[i] = offSourceTable + newSt.length;

    // 1. uri: UInt30 byteLength + UTF-8 bytes
    final uStart = pos;
    final uLen = readUInt30();
    pos += uLen;
    newSt.add(Uint8List.sublistView(data, uStart, pos));

    // 2. sourceCode: UInt30 byteLength + UTF-8 bytes -> replace with empty (0x00)
    final sLen = readUInt30();
    pos += sLen;
    newSt.addByte(0);

    // 3. lineStarts: UInt30 count + count * UInt30 delta
    final lsStart = pos;
    final lineCount = readUInt30();
    for (var j = 0; j < lineCount; j++) {
      readUInt30();
    }
    // 4. importUri: UInt30 byteLength + UTF-8 bytes
    final iuLen = readUInt30();
    pos += iuLen;
    // 5. constantCoverageConstructors: UInt30 count + count * UInt30
    final ccCount = readUInt30();
    for (var j = 0; j < ccCount; j++) {
      readUInt30();
    }
    newSt.add(Uint8List.sublistView(data, lsStart, pos));
  }

  final offsetsBuf = ByteData(numSources * 4);
  for (var i = 0; i < numSources; i++) {
    offsetsBuf.setUint32(i * 4, newSourceOffsets[i]);
  }
  newSt.add(offsetsBuf.buffer.asUint8List());

  final newStBytes = newSt.takeBytes();
  final oldStLen = offConstantTable - offSourceTable;
  final delta = newStBytes.length - oldStLen;
  if (delta == 0) return data;

  pos = offLinkTable;
  final canonCount = readUInt30();
  for (var i = 0; i < canonCount; i++) {
    readUInt30();
    readUInt30();
  }
  final linkTableEnd = pos <= offMetadataPayloads ? pos : offMetadataPayloads;

  final out = BytesBuilder(copy: false);
  out.add(Uint8List.sublistView(data, 0, offSourceTable));
  out.add(newStBytes);
  out.add(Uint8List.sublistView(data, offConstantTable, linkTableEnd));

  // Kernel requires binaryOffsetForMetadataPayloads (fields[4]) to be 8-byte
  // aligned (ComponentFile.metadataPayloadsAlignment = 8).
  final metaPad = (8 - (out.length % 8)) % 8;
  if (metaPad > 0) {
    out.add(Uint8List(metaPad));
  }
  final newOffMetadataPayloads = out.length;
  final metaDelta = newOffMetadataPayloads - offMetadataPayloads;

  out.add(Uint8List.sublistView(data, offMetadataPayloads, offComponentIndex));

  final newOffComponentIndex = out.length;
  final totalUnpadded = out.length + idxBytes;
  final pad = (8 - (totalUnpadded % 8)) % 8;
  if (pad > 0) {
    out.add(Uint8List(pad));
  }

  for (var i = 1; i <= 3; i++) {
    fields[i] += delta;
  }
  for (var i = 4; i <= 6; i++) {
    fields[i] += metaDelta;
  }
  fields[7] = newOffComponentIndex;
  fields[idxCount - 1] = out.length + idxBytes;

  final idxBuf = ByteData(idxBytes);
  for (var i = 0; i < idxCount; i++) {
    idxBuf.setUint32(i * 4, fields[i]);
  }
  out.add(idxBuf.buffer.asUint8List());
  return out.takeBytes();
}

const _x64SplitCommasPattern = <int>[
  0x48, 0x8b, 0x45, 0xf0, // mov rax, [rbp-0x10]
  0x48, 0x8b, 0x48, 0x5f, // mov rcx, [rax+0x5f]
  0xf6, 0xc1, 0x10, // test cl, 0x10
  0x0f, 0x85, 0x3a, 0x01, 0x00, 0x00, // jnz +0x13a
  0x48, 0x8b, 0x4d, 0xe8, // mov rcx, [rbp-0x18]
  0x8b, 0x51, 0xff, // mov edx, [rcx-0x1]
];

const _arm64SplitCommasPattern = <int>[
  0xa3, 0x03, 0x5f, 0xf8, // ldur x3, [fp, #-16]
  0x60, 0xf0, 0x45, 0xf8, // ldur x0, [x3, #95]
  0xc0, 0x09, 0x20, 0x37, // tbnz w0, #4, +0x138
  0xa0, 0x83, 0x5e, 0xf8, // ldur x0, [fp, #-24]
  0x01, 0xf0, 0x5f, 0xf8, // ldur w1, [x0, #-1]
];

int _findBytesPattern(Uint8List haystack, List<int> needle) {
  final nLen = needle.length;
  final limit = haystack.length - nLen;
  if (limit < 0) return -1;
  final first = needle[0];
  for (var i = 0; i <= limit; i++) {
    if (haystack[i] != first) continue;
    var match = true;
    for (var j = 1; j < nLen; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// Patches `Parser._setOption` in a `kernel_worker` or `gen_kernel` AOT
/// snapshot byte buffer so `addMultiOption` options (`-D` / `--define`) do not
/// split values on `,` (`0x2C`), allowing comma-containing defines to reach
/// the front end's constant evaluation unchanged.
///
/// Returns `true` if the pattern was found and patched in [bytes].
bool patchSnapshotSplitCommasBytes(Uint8List bytes) {
  final x64Idx = _findBytesPattern(bytes, _x64SplitCommasPattern);
  if (x64Idx >= 0) {
    bytes[x64Idx + 11] = 0x90; // nop
    bytes[x64Idx + 12] = 0xe9; // jmp rel32 (+0x13a)
    return true;
  }
  final arm64Idx = _findBytesPattern(bytes, _arm64SplitCommasPattern);
  if (arm64Idx >= 0) {
    bytes[arm64Idx + 8] = 0x4e; // b +0x138
    bytes[arm64Idx + 9] = 0x00;
    bytes[arm64Idx + 10] = 0x00;
    bytes[arm64Idx + 11] = 0x14;
    return true;
  }
  return false;
}

/// Returns the path to a cached copy of [snapshotPath] with
/// `Parser._setOption`'s comma-splitting disabled, or [snapshotPath] if the
/// file does not match a known AOT snapshot pattern.
String patchSnapshotSplitCommas(String snapshotPath) {
  final file = File(_filePathOf(snapshotPath));
  if (!file.existsSync()) return snapshotPath;
  final Uint8List bytes;
  try {
    bytes = file.readAsBytesSync();
  } on FileSystemException {
    return snapshotPath;
  }
  var hash = 0xcbf29ce484222325;
  for (var i = 0; i < bytes.length; i += 64) {
    hash ^= bytes[i];
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  final baseName = snapshotPath
      .replaceAll(r'\', '/')
      .split('/')
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final cacheFile = File(
    '${Directory.systemTemp.path}/'
    'rules_dart_nocomma_${baseName}_${bytes.length}_'
    '${hash.toRadixString(16)}.snapshot',
  );
  if (cacheFile.existsSync() && cacheFile.lengthSync() == bytes.length) {
    return cacheFile.path;
  }
  if (!patchSnapshotSplitCommasBytes(bytes)) {
    return snapshotPath;
  }
  final tmpFile = File(
    '${cacheFile.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    tmpFile.writeAsBytesSync(bytes, flush: true);
    if (Platform.isMacOS) {
      Process.runSync('/usr/bin/codesign', ['-f', '-s', '-', tmpFile.path]);
    }
    try {
      tmpFile.renameSync(cacheFile.path);
    } on FileSystemException {
      if (!cacheFile.existsSync()) {
        tmpFile.copySync(cacheFile.path);
      }
      if (tmpFile.existsSync()) {
        tmpFile.deleteSync();
      }
    }
    return cacheFile.path;
  } on FileSystemException {
    try {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    } on FileSystemException {
      // Ignore cleanup errors.
    }
    return snapshotPath;
  }
}
