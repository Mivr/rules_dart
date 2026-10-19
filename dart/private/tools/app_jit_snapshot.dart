// Trains an app-JIT snapshot, so that the snapshot does not depend on where or
// how it was built.
//
// Two rules use it: `dart_binary` in `jit-snapshot` mode, which trains on the
// program itself, and `dart_test_runner_snapshot`, which trains the
// `package:test` runner on one real test. It is pure Dart (no shell), so it
// runs on any host the rules support. The exec SDK's `dart` runs it from
// source, so it needs no build of its own.
//
// Usage:
//   dart app_jit_snapshot.dart --dart=<dart> --sdk-version=<version> \
//       --snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] \
//       [--env=KEY=VALUE]... [--copy=DEST=SOURCE]... [--copy-tree=DEST=DIR]... \
//       -- <dart arguments>
//
// The `<dart arguments>` are what `dart` runs in the training: the script
// first, then its own arguments. Paths in them are relative to the scratch
// directory, where each `--copy` and `--copy-tree` places its files.
//
// The snapshot should not depend on how it was built. Four things aim at that:
//  * `--deterministic` makes the VM's own choices repeat, so one training run
//    and the next write the same bytes. `--no-background-compilation` keeps
//    optimizing compiles on the training thread.
//  * The absolute length of the directory the training runs in changes the
//    snapshot. So the training runs in a scratch directory whose name has a
//    fixed length (a random suffix of fixed length), under relative arguments.
//    The scratch directory is private to the run, so concurrent actions that
//    share a `/tmp` cannot collide. On Windows there is no such root, and the
//    rules build no snapshot there.
//  * The environment names nothing but paths relative to the scratch directory.
//  * The training VM runs from a fixed path, `/tmp/rules_dart_vm-<version>/bin`,
//    which holds a copy of the SDK's `dart` (and `dartvm`). The absolute path of
//    the training binary changes the snapshot, so a copy at one path per SDK
//    version is what makes the snapshot the same across SDK installs. Every
//    copy is byte-identical, so concurrent actions may write the same file.
//
// A program whose own training run is not deterministic (it reads the clock,
// random numbers, or files outside the build) yields a snapshot that differs
// between builds, whatever this tool does.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

void main(List<String> argv) {
  if (argv.isNotEmpty && argv.first == '--aot') {
    _runAot(argv.sublist(1));
    return;
  }
  if (argv.isNotEmpty && argv.first == '--gen-kernel') {
    _runGenKernel(argv.sublist(1));
    return;
  }
  String? dart;
  String? dartvm;
  String? sdkVersion;
  String? snapshot;
  var enableAsserts = false;
  final env = <String, String>{};
  final copies = <_Pair>[];
  final trees = <_Pair>[];

  var i = 0;
  for (; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--') {
      i++;
      break;
    }
    if (arg == '--enable-asserts') {
      enableAsserts = true;
      continue;
    }
    final eq = arg.indexOf('=');
    if (eq < 0) _usage('unknown argument $arg');
    final name = arg.substring(0, eq);
    final value = arg.substring(eq + 1);
    switch (name) {
      case '--dart':
        dart = value;
      case '--dartvm':
        dartvm = value;
      case '--sdk-version':
        sdkVersion = value;
      case '--snapshot':
        snapshot = value;
      case '--env':
        final pair = _Pair.parse(value, arg);
        env[pair.key] = pair.value;
      case '--copy':
        copies.add(_Pair.parse(value, arg));
      case '--copy-tree':
        trees.add(_Pair.parse(value, arg));
      default:
        _usage('unknown argument $arg');
    }
  }
  final dartArgs = argv.sublist(i);
  if (dart == null ||
      sdkVersion == null ||
      snapshot == null ||
      dartArgs.isEmpty) {
    _usage(
      '--dart, --sdk-version, --snapshot and the dart arguments are required',
    );
  }

  final out = File(snapshot).absolute;
  final trainingVm = _stableVm(
    dart: File(dart).absolute.path,
    dartvm: dartvm == null ? null : File(dartvm).absolute.path,
    sdkVersion: sdkVersion,
  );
  final exitCode = _trainInScratch(
    dart: trainingVm,
    dartArgs: dartArgs,
    enableAsserts: enableAsserts,
    env: env,
    copies: [for (final c in copies) _Pair(c.key, File(c.value).absolute.path)],
    trees: [
      for (final t in trees) _Pair(t.key, Directory(t.value).absolute.path),
    ],
    out: out,
  );
  if (exitCode != 0) exit(exitCode);
  if (!out.existsSync()) {
    stderr.writeln(
      'app_jit_snapshot: the training run of ${dartArgs.first} wrote no '
      'snapshot to ${out.path}',
    );
    exit(1);
  }
}

Never _usage(String problem) {
  stderr.writeln(
    'app_jit_snapshot: $problem\n'
    'usage: dart app_jit_snapshot.dart --dart=<dart> --sdk-version=<v> '
    '--snapshot=<out> [--dartvm=<dartvm>] [--enable-asserts] [--env=K=V]... '
    '[--copy=D=S]... [--copy-tree=D=DIR]... -- <dart arguments>',
  );
  exit(64);
}

/// Returns the path of the training `dart`: a copy at a fixed path for
/// [sdkVersion], made from [dart] and [dartvm] when they are not there yet.
///
/// Under the Linux sandbox `/tmp` is private to each action, so the copy is
/// removed with the action. Elsewhere one copy per SDK version stays in `/tmp`,
/// and it is not deleted afterwards: another action may be using it. A version
/// is taken to name one binary; a copy with other bytes is replaced.
String _stableVm({
  required String dart,
  required String? dartvm,
  required String sdkVersion,
}) {
  final exeExt = dart.endsWith('.exe') ? '.exe' : '';
  final root = Platform.isWindows ? Directory.systemTemp.path : '/tmp';
  final bin = Directory('$root/rules_dart_vm-$sdkVersion/bin');
  bin.createSync(recursive: true);
  _installCopy(dart, '${bin.path}/dart$exeExt');
  final effectiveDartvm = dartvm ?? _adjacentDartvm(dart, exeExt);
  if (effectiveDartvm != null) {
    final vmExt = effectiveDartvm.endsWith('.exe') ? '.exe' : '';
    _installCopy(effectiveDartvm, '${bin.path}/dartvm$vmExt');
  }
  return '${bin.path}/dart$exeExt';
}

String? _adjacentDartvm(String dart, String exeExt) {
  final candidate = File('${File(dart).parent.path}/dartvm$exeExt');
  return candidate.existsSync() ? candidate.path : null;
}

/// Makes [target] an executable copy of [source], unless it is one already.
///
/// The copy is written under a name unique to this process, marked `0755`, then
/// renamed over [target]. A rename replaces the file in one step, so a reader
/// sees the old file or the new one, never a partial copy, and a process that
/// is running the old file keeps it.
void _installCopy(String source, String target) {
  final src = File(source);
  final dst = File(target);
  if (dst.existsSync() &&
      dst.lengthSync() == src.lengthSync() &&
      _sameBytes(src, dst)) {
    return;
  }
  final tmp = File('$target.$pid.${Random().nextInt(1 << 31)}.tmp');
  tmp.writeAsBytesSync(src.readAsBytesSync());
  chmodFile(tmp.path, 0x1ed);
  try {
    tmp.renameSync(target);
  } on FileSystemException {
    if (!dst.existsSync()) rethrow;
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Ignore cleanup errors.
    }
  }
}

bool _sameBytes(File a, File b) {
  final x = a.readAsBytesSync();
  final y = b.readAsBytesSync();
  if (x.length != y.length) return false;
  for (var i = 0; i < x.length; i++) {
    if (x[i] != y[i]) return false;
  }
  return true;
}

const _isolatedHomeEnvKeys = <String>{
  'HOME',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'PUB_CACHE',
  'TEMP',
  'TMP',
  'TMPDIR',
  'XDG_CONFIG_HOME',
  'XDG_CACHE_HOME',
};

String? _lookupEnvCaseInsensitive(Map<String, String> env, String name) {
  final direct = env[name];
  if (direct != null && direct.isNotEmpty && !direct.contains('\x00')) {
    return direct;
  }
  final upper = name.toUpperCase();
  for (final entry in env.entries) {
    if (entry.key.toUpperCase() == upper &&
        entry.value.isNotEmpty &&
        !entry.value.contains('\x00')) {
      return entry.value;
    }
  }
  return null;
}

/// Builds a sanitized child-process environment isolated to [homeDir].
///
/// On Windows ([isWindows]), keeps the minimal system variables Windows needs
/// to start a process (`SystemRoot`, `WINDIR`, `SystemDrive`, `COMSPEC`,
/// `PATHEXT`, `PATH`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_ARCHITECTURE`) from
/// [parentEnv] (falling back to `C:\Windows` for `SystemRoot` when absent),
/// and points the home, cache, and temporary directory variables
/// (`USERPROFILE`, `LOCALAPPDATA`, `APPDATA`, `HOME`, `PUB_CACHE`, `TEMP`,
/// `TMP`, `TMPDIR`) at [homeDir]. Any entry with an empty name or `=` in the
/// name is omitted.
Map<String, String> buildChildEnvironment({
  required String homeDir,
  Map<String, String>? parentEnv,
  Map<String, String> overrides = const {},
  bool? isWindows,
  bool includeParent = true,
}) {
  final source = parentEnv ?? Platform.environment;
  final win = isWindows ?? Platform.isWindows;
  final result = <String, String>{};

  bool isValidEntry(String key, String value) =>
      key.isNotEmpty &&
      !key.contains('=') &&
      !key.contains('\x00') &&
      !value.contains('\x00');

  void setEnv(String key, String value) {
    if (!isValidEntry(key, value)) return;
    if (win) {
      final upper = key.toUpperCase();
      result.removeWhere(
        (existingKey, _) => existingKey.toUpperCase() == upper,
      );
    }
    result[key] = value;
  }

  if (win) {
    final systemRoot =
        _lookupEnvCaseInsensitive(source, 'SystemRoot') ??
        _lookupEnvCaseInsensitive(source, 'WINDIR') ??
        r'C:\Windows';
    final systemDrive =
        _lookupEnvCaseInsensitive(source, 'SystemDrive') ??
        (systemRoot.length >= 2 && systemRoot[1] == ':'
            ? systemRoot.substring(0, 2)
            : 'C:');
    setEnv('SystemRoot', systemRoot);
    setEnv('WINDIR', _lookupEnvCaseInsensitive(source, 'WINDIR') ?? systemRoot);
    setEnv('SystemDrive', systemDrive);
    setEnv(
      'COMSPEC',
      _lookupEnvCaseInsensitive(source, 'COMSPEC') ??
          '$systemRoot\\System32\\cmd.exe',
    );
    setEnv(
      'PATHEXT',
      _lookupEnvCaseInsensitive(source, 'PATHEXT') ?? '.COM;.EXE;.BAT;.CMD',
    );
    final parentPath = _lookupEnvCaseInsensitive(source, 'PATH');
    setEnv(
      'PATH',
      (includeParent && parentPath != null)
          ? parentPath
          : '$systemRoot\\System32;$systemRoot',
    );
    for (final optionalKey in const [
      'NUMBER_OF_PROCESSORS',
      'PROCESSOR_ARCHITECTURE',
    ]) {
      final val = _lookupEnvCaseInsensitive(source, optionalKey);
      if (val != null) {
        setEnv(optionalKey, val);
      }
    }
    for (final homeKey in const [
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'HOME',
      'PUB_CACHE',
      'TEMP',
      'TMP',
      'TMPDIR',
    ]) {
      setEnv(homeKey, homeDir);
    }
    for (final entry in overrides.entries) {
      setEnv(entry.key, entry.value);
    }
    if ((_lookupEnvCaseInsensitive(result, 'SystemRoot') ?? '').isEmpty) {
      setEnv('SystemRoot', systemRoot);
    }
    return result;
  }

  if (includeParent) {
    for (final entry in source.entries) {
      if (_isolatedHomeEnvKeys.contains(entry.key.toUpperCase())) continue;
      setEnv(entry.key, entry.value);
    }
    for (final homeKey in const [
      'HOME',
      'USERPROFILE',
      'LOCALAPPDATA',
      'APPDATA',
      'PUB_CACHE',
    ]) {
      setEnv(homeKey, homeDir);
    }
  } else {
    setEnv('HOME', homeDir);
    setEnv('TMPDIR', homeDir);
  }
  for (final entry in overrides.entries) {
    setEnv(entry.key, entry.value);
  }
  return result;
}

/// A `KEY=VALUE` (or `DEST=SOURCE`) option value. Splits at the first `=`.
class _Pair {
  const _Pair(this.key, this.value);

  final String key;
  final String value;

  static _Pair parse(String text, String arg) {
    final eq = text.indexOf('=');
    if (eq < 0) _usage('expected KEY=VALUE in $arg');
    return _Pair(text.substring(0, eq), text.substring(eq + 1));
  }
}

/// Runs the training in a fresh scratch directory and copies the snapshot it
/// writes to [out]. Returns the training run's exit code.
///
/// The scratch directory is removed whatever the outcome. `exit` is not called
/// in here: it would skip the cleanup.
int _trainInScratch({
  required String dart,
  required List<String> dartArgs,
  required bool enableAsserts,
  required Map<String, String> env,
  required List<_Pair> copies,
  required List<_Pair> trees,
  required File out,
}) {
  // A private directory per run, so concurrent snapshot actions that share a
  // `/tmp` (no sandbox, or a shared one) cannot collide. The random suffix is
  // fixed-length, so the absolute path has the same length on every run.
  final scratchRoot = Platform.isWindows
      ? Directory.systemTemp
      : Directory('/tmp');
  final scratch = scratchRoot.createTempSync('rules_dart_snapshot.');
  try {
    // Every input is copied to its relative place, so the run needs only
    // relative paths.
    for (final c in copies) {
      _copyFile(c.value, '${scratch.path}/${c.key}');
    }
    for (final t in trees) {
      _copyTree(t.value, '${scratch.path}/${t.key}');
    }
    File('${scratch.path}/.dart_tool/package_config.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{"configVersion": 2, "packages": []}\n');

    final childEnv = buildChildEnvironment(
      homeDir: Platform.isWindows ? scratch.path : '.',
      parentEnv: Platform.environment,
      overrides: env,
      isWindows: Platform.isWindows,
      includeParent: false,
    );

    // The training run keeps the VM flags that make the snapshot repeat, and
    // none that name a host path. The scratch directory is the working
    // directory, so every relative path resolves inside it.
    //
    // The runner keeps its default reporter and timeout, and no file reporter
    // is passed. With the file reporter, and with the explicit reporter and
    // timeout, the same inputs gave different snapshots from one run to the
    // next; with none of them, ten runs gave one snapshot. Nothing here reads a
    // report, and the test's exit code is all the training needs.
    final result = Process.runSync(
      dart,
      [
        '--deterministic',
        // Optimizing compilation stays on the training thread, so the functions
        // the snapshot holds optimized do not depend on when a background
        // compile happens to finish. (The stability measured for this tool was
        // with the flag in place; its own contribution was not measured
        // separately.)
        '--no-background-compilation',
        // Code for the VM's baseline CPU rather than the build machine's. The
        // intent is cross-CPU identity, so a cache can share the snapshot.
        '--target_unknown_cpu',
        if (enableAsserts) '--enable-asserts',
        '--packages=.dart_tool/package_config.json',
        '--snapshot-kind=app-jit',
        '--snapshot=snapshot.jit',
        ...dartArgs,
      ],
      workingDirectory: scratch.path,
      environment: childEnv,
      includeParentEnvironment: false,
    );

    // Bazel echoes any action output, so a clean run stays silent.
    if (result.exitCode != 0) {
      stdout.write(result.stdout as String);
      stderr.write(result.stderr as String);
      return result.exitCode;
    }
    final written = File('${scratch.path}/snapshot.jit');
    if (written.existsSync()) {
      out.parent.createSync(recursive: true);
      out.writeAsBytesSync(written.readAsBytesSync());
    }
    return 0;
  } finally {
    if (scratch.existsSync()) {
      try {
        scratch.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
}

/// Copies every file under [from] to the same relative place under [to].
void _copyTree(String from, String to) {
  final source = Directory(from);
  final entities = source.listSync(recursive: true)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    if (entity is File) {
      final relative = entity.path.substring(source.path.length + 1);
      _copyFile(entity.path, '$to/$relative');
    }
  }
}

/// Copies [from] to [to] by content, creating the parent directories of [to].
///
/// Writes bytes rather than `File.copySync` so read-only input modes from a
/// sandbox or remote executor are not carried onto the scratch copy.
void _copyFile(String from, String to) {
  final dest = File(to);
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(File(from).readAsBytesSync());
}

/// Compiles a pre-built kernel `.dill` to an AOT snapshot (`--mode=aot-snapshot`)
/// or self-contained AOT executable (`--mode=exe`) without invoking `dartdev`.
///
/// `dart compile exe` runs through `dartdev`, which walks ancestor directories
/// up to `/` probing `pubspec.yaml` and `.dart_tool/package_config.json` (for
/// native-asset hook discovery) and spawns `/usr/bin/chmod` via `PATH`. Driving
/// `gen_snapshot --deterministic` directly and writing a fresh executable from
/// `dartaotruntime` plus the ELF snapshot (marking it `0755` via libc `chmod`)
/// keeps the compile strictly hermetic inside the action sandbox, even when
/// inputs are staged read-only and no shell or coreutils exist.
void _runAot(List<String> argv) {
  String? dart;
  String? mode;
  String? recordedUses;
  String? outputPath;
  String? dillPath;
  String? customGenSnapshot;
  String? customDartaotruntime;
  String? targetOs;
  String? targetArch;
  var enableAsserts = false;
  final extraGenSnapshotOptions = <String>[];

  for (var i = 0; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--enable-asserts') {
      enableAsserts = true;
    } else if (arg == '--verbosity=error') {
      // Ignored: gen_snapshot is silent on success.
    } else if (arg.startsWith('--dart=')) {
      dart = arg.substring('--dart='.length);
    } else if (arg.startsWith('--mode=')) {
      mode = arg.substring('--mode='.length);
    } else if (arg.startsWith('--recorded-uses=')) {
      recordedUses = arg.substring('--recorded-uses='.length);
    } else if (arg.startsWith('--gen-snapshot=')) {
      customGenSnapshot = arg.substring('--gen-snapshot='.length);
    } else if (arg == '--gen-snapshot') {
      customGenSnapshot = argv[++i];
    } else if (arg.startsWith('--dartaotruntime=')) {
      customDartaotruntime = arg.substring('--dartaotruntime='.length);
    } else if (arg == '--dartaotruntime') {
      customDartaotruntime = argv[++i];
    } else if (arg.startsWith('--target-os=')) {
      targetOs = arg.substring('--target-os='.length);
    } else if (arg == '--target-os') {
      targetOs = argv[++i];
    } else if (arg.startsWith('--target-arch=')) {
      targetArch = arg.substring('--target-arch='.length);
    } else if (arg == '--target-arch') {
      targetArch = argv[++i];
    } else if (arg.startsWith('--extra-gen-snapshot-options=')) {
      final opts = arg.substring('--extra-gen-snapshot-options='.length);
      for (final opt in opts.split(',')) {
        if (opt.isNotEmpty) extraGenSnapshotOptions.add(opt);
      }
    } else if (arg == '-o') {
      outputPath = argv[++i];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (!arg.startsWith('-')) {
      dillPath = arg;
    } else {
      stderr.writeln('app_jit_snapshot --aot: unknown argument $arg');
      exit(64);
    }
  }

  if (dart == null || mode == null || outputPath == null || dillPath == null) {
    stderr.writeln(
      'app_jit_snapshot --aot: --dart, --mode, -o, and input dill are required',
    );
    exit(64);
  }

  final isCross =
      (targetOs != null && targetOs.isNotEmpty) ||
      (targetArch != null && targetArch.isNotEmpty);
  if (isCross) {
    if (customGenSnapshot == null || customGenSnapshot.isEmpty) {
      stderr.writeln(
        'app_jit_snapshot --aot: cross-compilation to $targetOs-$targetArch '
        'requires --gen-snapshot',
      );
      exit(64);
    }
    if (mode == 'exe' &&
        (customDartaotruntime == null || customDartaotruntime.isEmpty)) {
      stderr.writeln(
        'app_jit_snapshot --aot: cross-compiling exe to $targetOs-$targetArch '
        'requires --dartaotruntime',
      );
      exit(64);
    }
  }

  final sdkBin = File(dart).parent.path;
  final hostExeExt = dart.endsWith('.exe') ? '.exe' : '';
  final hostDartaotruntime = '$sdkBin/dartaotruntime$hostExeExt';
  final targetDartaotruntime = customDartaotruntime ?? hostDartaotruntime;
  final genSnapshot =
      customGenSnapshot ?? '$sdkBin/utils/gen_snapshot$hostExeExt';

  // On non-ELF targets (e.g. native macOS Mach-O executables or Windows) or
  // jit-snapshot fallback on Windows, delegate to `dart compile` with a fresh
  // temporary HOME directory. Cross-compilation targets are always ELF and
  // never delegate to `dartdev`.
  if (!isCross &&
      (mode == 'jit-snapshot' ||
          dart.endsWith('.exe') ||
          (mode == 'exe' && !_isElfFile(File(targetDartaotruntime))))) {
    final compileArgs = <String>[
      'compile',
      mode,
      if (mode == 'exe' || mode == 'aot-snapshot') '--verbosity=error',
      if (enableAsserts) '--enable-asserts',
      if (recordedUses != null) '--recorded-uses=$recordedUses',
      for (final opt in extraGenSnapshotOptions)
        '--extra-gen-snapshot-options=$opt',
      '-o',
      outputPath,
      dillPath,
    ];
    final tempHome = Directory.systemTemp.createTempSync(
      'rules_dart_compile_home.',
    );
    final childEnv = buildChildEnvironment(
      homeDir: tempHome.path,
      parentEnv: Platform.environment,
      isWindows: Platform.isWindows,
    );
    final ProcessResult res;
    try {
      res = Process.runSync(
        dart,
        compileArgs,
        environment: childEnv,
        includeParentEnvironment: false,
      );
    } finally {
      if (tempHome.existsSync()) {
        try {
          tempHome.deleteSync(recursive: true);
        } on FileSystemException {
          // Ignore cleanup errors.
        }
      }
    }
    if (res.exitCode != 0) {
      stdout.write(res.stdout as String);
      stderr.write(res.stderr as String);
      exit(res.exitCode);
    }
    return;
  }

  final tmpDir = Directory.systemTemp.createTempSync('rules_dart_aot.');
  final homeDir = Directory('${tmpDir.path}/home')..createSync(recursive: true);
  final homeEnv = buildChildEnvironment(
    homeDir: homeDir.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  var failureExitCode = 0;
  try {
    var activeDill = dillPath;
    if (recordedUses != null) {
      final productPlatform =
          '$sdkBin/../lib/_internal/vm_platform_product.dill';
      final strongPlatform = '$sdkBin/../lib/_internal/vm_platform_strong.dill';
      final platformDill = File(productPlatform).existsSync()
          ? productPlatform
          : strongPlatform;
      final recordedDill = '${tmpDir.path}/recorded.dill';
      final gkRes = Process.runSync(
        hostDartaotruntime,
        [
          '$sdkBin/snapshots/gen_kernel_aot.dart.snapshot',
          '--platform=$platformDill',
          '--aot',
          '--tfa',
          '--no-embed-sources',
          '-Ddart.vm.product=true',
          '-Ddart.vm.asan=false',
          '-Ddart.vm.msan=false',
          '-Ddart.vm.tsan=false',
          if (targetOs != null && targetOs.isNotEmpty) '--target-os=$targetOs',
          if (enableAsserts) '--enable-asserts',
          '--from-dill=$dillPath',
          '--recorded-usages-file=$recordedUses',
          '-o',
          recordedDill,
          dillPath,
        ],
        environment: homeEnv,
        includeParentEnvironment: false,
      );
      if (gkRes.exitCode != 0) {
        stdout.write(gkRes.stdout as String);
        stderr.write(gkRes.stderr as String);
        failureExitCode = gkRes.exitCode;
        return;
      }
      activeDill = recordedDill;
    }

    final elfPath = mode == 'aot-snapshot'
        ? outputPath
        : '${tmpDir.path}/snapshot.elf';
    final gsRes = Process.runSync(
      genSnapshot,
      [
        '--deterministic',
        '--snapshot_kind=app-aot-elf',
        '--elf=$elfPath',
        if (enableAsserts) '--enable_asserts',
        ...extraGenSnapshotOptions,
        activeDill,
      ],
      environment: homeEnv,
      includeParentEnvironment: false,
    );
    if (gsRes.exitCode != 0) {
      stdout.write(gsRes.stdout as String);
      stderr.write(gsRes.stderr as String);
      failureExitCode = gsRes.exitCode;
      return;
    }

    if (mode == 'exe') {
      writeAppAotElfExe(
        dartaotruntime: File(targetDartaotruntime),
        snapshotElf: File(elfPath),
        output: File(outputPath),
      );
    }
  } finally {
    if (tmpDir.existsSync()) {
      try {
        tmpDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if (failureExitCode != 0) {
    exit(failureExitCode);
  }
}

bool _isElfFile(File file) {
  if (!file.existsSync()) return false;
  final raf = file.openSync();
  try {
    final magic = raf.readSync(4);
    return magic.length == 4 &&
        magic[0] == 0x7f &&
        magic[1] == 0x45 &&
        magic[2] == 0x4c &&
        magic[3] == 0x46;
  } finally {
    raf.closeSync();
  }
}

/// Writes a self-contained AOT ELF executable to [output] by concatenating
/// [dartaotruntime], zero padding up to a 64 KiB page boundary, [snapshotElf],
/// and the 16-byte app-JIT/AOT trailer, then marks [output] executable (`0755`).
///
/// Does not use `File.copySync`: under remote execution and read-only sandboxes,
/// [dartaotruntime] has mode `0555` (or `0444`), and `copySync` copies that
/// read-only mode onto [output], causing a subsequent open for append to fail
/// with `EACCES`. Writing a fresh file and setting `0755` via `libc`'s `chmod`
/// avoids both copying read-only permissions and spawning `/bin/chmod`.
void writeAppAotElfExe({
  required File dartaotruntime,
  required File snapshotElf,
  required File output,
}) {
  const pageSize = 65536;
  output.parent.createSync(recursive: true);
  if (output.existsSync()) {
    output.deleteSync();
  }
  final runtimeBytes = dartaotruntime.readAsBytesSync();
  final runtimeLen = runtimeBytes.length;
  final padLen = (pageSize - (runtimeLen % pageSize)) % pageSize;
  final offset = runtimeLen + padLen;

  final raf = output.openSync(mode: FileMode.writeOnly);
  try {
    raf.writeFromSync(runtimeBytes);
    if (padLen > 0) {
      raf.writeFromSync(Uint8List(padLen));
    }
    raf.writeFromSync(snapshotElf.readAsBytesSync());
    final trailer = ByteData(16)
      ..setUint64(0, offset, Endian.little)
      ..setUint8(8, 0xdc)
      ..setUint8(9, 0xdc)
      ..setUint8(10, 0xf6)
      ..setUint8(11, 0xf6)
      ..setUint8(12, 0x00)
      ..setUint8(13, 0x00)
      ..setUint8(14, 0x00)
      ..setUint8(15, 0x00);
    raf.writeFromSync(trailer.buffer.asUint8List());
  } finally {
    raf.closeSync();
  }
  chmodFile(output.path, 0x1ed);
}

typedef _MallocNative = ffi.Pointer<ffi.Uint8> Function(ffi.Size);
typedef _MallocDart = ffi.Pointer<ffi.Uint8> Function(int);
typedef _FreeNative = ffi.Void Function(ffi.Pointer<ffi.Uint8>);
typedef _FreeDart = void Function(ffi.Pointer<ffi.Uint8>);
typedef _ChmodNative = ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32);
typedef _ChmodDart = int Function(ffi.Pointer<ffi.Uint8>, int);

/// Sets POSIX permission bits [mode] on [path] via libc's `chmod(2)`.
void chmodFile(String path, int mode) {
  if (Platform.isWindows) return;
  final lib = ffi.DynamicLibrary.process();
  final malloc = lib.lookupFunction<_MallocNative, _MallocDart>('malloc');
  final free = lib.lookupFunction<_FreeNative, _FreeDart>('free');
  final chmod = lib.lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  final bytes = utf8.encode(path);
  final ptr = malloc(bytes.length + 1);
  if (ptr == ffi.nullptr) {
    throw FileSystemException('malloc failed for chmod', path);
  }
  try {
    ptr.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    final rc = chmod(ptr, mode);
    if (rc != 0) {
      throw FileSystemException('chmod failed (rc=$rc)', path);
    }
  } finally {
    free(ptr);
  }
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
  final file = File(snapshotPath);
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

void _copyEntitySync(String srcPath, String dstPath) {
  final type = FileSystemEntity.typeSync(srcPath);
  if (type == FileSystemEntityType.file) {
    final dst = File(dstPath);
    if (dst.existsSync()) return;
    dst.parent.createSync(recursive: true);
    dst.writeAsBytesSync(File(srcPath).readAsBytesSync());
  } else if (type == FileSystemEntityType.directory) {
    for (final entity in Directory(srcPath).listSync(recursive: true)) {
      if (entity is File) {
        final rel = entity.path
            .substring(srcPath.length)
            .replaceAll(r'\', '/')
            .replaceFirst(RegExp(r'^/+'), '');
        final childDst = '$dstPath/$rel';
        if (FileSystemEntity.typeSync(childDst) !=
            FileSystemEntityType.notFound) {
          continue;
        }
        File(childDst).parent.createSync(recursive: true);
        File(childDst).writeAsBytesSync(File(entity.path).readAsBytesSync());
      }
    }
  }
}

String _stripFsRootPrefix(String path, List<String> fsRoots) {
  final slashPath = path.replaceAll(r'\', '/');
  var bestRootLen = -1;
  String? bestRel;
  for (final rawRoot in fsRoots) {
    final root = rawRoot.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
    if (root.isEmpty || root == '.') continue;
    final prefix = '$root/';
    if (slashPath.startsWith(prefix) && root.length > bestRootLen) {
      bestRootLen = root.length;
      bestRel = slashPath.substring(prefix.length);
    }
  }
  return bestRel ?? slashPath.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

/// Runs `gen_kernel` via `dartaotruntime` with comma-splitting disabled on
/// `-D` / `--define` options and an isolated `--filesystem-root` containing
/// only declared input sources.
void _runGenKernel(List<String> argv) {
  if (argv.length < 2) {
    stderr.writeln(
      'app_jit_snapshot --gen-kernel: expected <dartaotruntime> <gen_kernel_args...>',
    );
    exit(64);
  }
  final dartaotruntime = argv.first;
  final rawGenArgs = <String>[];
  final declaredInputSources = <String>[];
  final fsRoots = <String>[];
  String? outputPath;
  for (var i = 1; i < argv.length; i++) {
    final arg = argv[i];
    if (arg == '--input-source' && i + 1 < argv.length) {
      declaredInputSources.add(argv[++i]);
      continue;
    }
    if (arg.startsWith('--input-source=')) {
      declaredInputSources.add(arg.substring('--input-source='.length));
      continue;
    }
    if (arg == '--input-sources-file' && i + 1 < argv.length) {
      final file = File(argv[++i]);
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) declaredInputSources.add(line);
        }
      }
      continue;
    }
    if (arg.startsWith('--input-sources-file=')) {
      final file = File(arg.substring('--input-sources-file='.length));
      if (file.existsSync()) {
        for (final line in file.readAsLinesSync()) {
          if (line.isNotEmpty) declaredInputSources.add(line);
        }
      }
      continue;
    }
    if (arg == '--filesystem-root' && i + 1 < argv.length) {
      fsRoots.add(argv[i + 1]);
    } else if (arg.startsWith('--filesystem-root=')) {
      fsRoots.add(arg.substring('--filesystem-root='.length));
    } else if ((arg == '-o' || arg == '--output') && i + 1 < argv.length) {
      outputPath = argv[i + 1];
    } else if (arg.startsWith('-o=')) {
      outputPath = arg.substring('-o='.length);
    } else if (arg.startsWith('--output=')) {
      outputPath = arg.substring('--output='.length);
    }
    rawGenArgs.add(arg);
  }

  // Only patch the gen_kernel snapshot when a define actually contains a comma:
  // the patch disables Parser._setOption's comma splitting, which is only
  // needed for comma-containing defines.
  var hasCommaDefines = false;
  for (var i = 0; i < rawGenArgs.length; i++) {
    final arg = rawGenArgs[i];
    if (arg == '-D' || arg == '--define') {
      if (i + 1 < rawGenArgs.length && rawGenArgs[i + 1].contains(',')) {
        hasCommaDefines = true;
      }
    } else if (arg.startsWith('-D') && arg.length > 2) {
      if (arg.substring(2).contains(',')) hasCommaDefines = true;
    } else if (arg.startsWith('--define=')) {
      if (arg.substring('--define='.length).contains(',')) {
        hasCommaDefines = true;
      }
    }
  }
  if (rawGenArgs.isNotEmpty && hasCommaDefines) {
    rawGenArgs[0] = patchSnapshotSplitCommas(rawGenArgs[0]);
  }

  // Only stage an isolated multi-root when an undeclared file would otherwise
  // shadow a declared input. In the common case (no shadows) skip staging.
  var hasShadowRisk = false;
  if (declaredInputSources.isNotEmpty && fsRoots.isNotEmpty) {
    for (final srcPath in declaredInputSources) {
      final key = _stripFsRootPrefix(srcPath, fsRoots);
      if (key.isEmpty) {
        hasShadowRisk = true;
        break;
      }
      final slashSrc = srcPath.replaceAll(r'\\', '/');
      var originFound = false;
      for (final root in fsRoots) {
        final slashRoot = root
            .replaceAll(r'\\', '/')
            .replaceFirst(RegExp(r'/+$'), '');
        if (slashSrc.startsWith('$slashRoot/')) {
          originFound = true;
          continue;
        }
        final candidate = slashRoot == '.' ? key : '$slashRoot/$key';
        if (File(candidate).existsSync()) {
          hasShadowRisk = true;
          break;
        }
      }
      if (hasShadowRisk) break;
      if (!originFound) {
        hasShadowRisk = true;
        break;
      }
    }
  }

  Directory? isolatedRootDir;
  final forwarded = <String>[];
  if (declaredInputSources.isNotEmpty && fsRoots.isNotEmpty && hasShadowRisk) {
    final baseDir = outputPath != null
        ? File(outputPath).parent
        : Directory.systemTemp;
    baseDir.createSync(recursive: true);
    isolatedRootDir = baseDir.createTempSync('.gen_kernel_root.');
    final seenKeys = <String>{};
    for (final srcPath in declaredInputSources) {
      final key = _stripFsRootPrefix(srcPath, fsRoots);
      if (key.isEmpty || !seenKeys.add(key)) continue;
      _copyEntitySync(srcPath, '${isolatedRootDir.path}/$key');
    }
    var insertedRoot = false;
    for (var i = 0; i < rawGenArgs.length; i++) {
      final arg = rawGenArgs[i];
      if (arg == '--filesystem-root' && i + 1 < rawGenArgs.length) {
        i++;
        if (!insertedRoot) {
          insertedRoot = true;
          forwarded
            ..add('--filesystem-root')
            ..add(isolatedRootDir.path);
        }
        continue;
      }
      if (arg.startsWith('--filesystem-root=')) {
        if (!insertedRoot) {
          insertedRoot = true;
          forwarded.add('--filesystem-root=${isolatedRootDir.path}');
        }
        continue;
      }
      forwarded.add(arg);
    }
  } else {
    forwarded.addAll(rawGenArgs);
  }

  final tempHome = Directory.systemTemp.createTempSync(
    'rules_dart_gen_kernel_home.',
  );
  final childEnv = buildChildEnvironment(
    homeDir: tempHome.path,
    parentEnv: Platform.environment,
    isWindows: Platform.isWindows,
  );
  final ProcessResult res;
  try {
    res = Process.runSync(
      dartaotruntime,
      forwarded,
      environment: childEnv,
      includeParentEnvironment: false,
    );
  } finally {
    if (isolatedRootDir != null && isolatedRootDir.existsSync()) {
      try {
        isolatedRootDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
    if (tempHome.existsSync()) {
      try {
        tempHome.deleteSync(recursive: true);
      } on FileSystemException {
        // Ignore cleanup errors.
      }
    }
  }
  if ((res.stdout as String).isNotEmpty) {
    stdout.write(res.stdout as String);
  }
  if ((res.stderr as String).isNotEmpty) {
    stderr.write(res.stderr as String);
  }
  if (res.exitCode != 0) {
    exit(res.exitCode);
  }
}
