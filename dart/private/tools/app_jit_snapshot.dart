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
import 'dart:io';
import 'dart:math';

void main(List<String> argv) {
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
  final bin = Directory('/tmp/rules_dart_vm-$sdkVersion/bin');
  bin.createSync(recursive: true);
  _installCopy(dart, '${bin.path}/dart');
  if (dartvm != null) _installCopy(dartvm, '${bin.path}/dartvm');
  return '${bin.path}/dart';
}

/// Makes [target] an executable copy of [source], unless it is one already.
///
/// The copy is written under a name unique to this process, then renamed over
/// [target]. A rename replaces the file in one step, so a reader sees the old
/// file or the new one, never a partial copy, and a process that is running
/// the old file keeps it.
void _installCopy(String source, String target) {
  final src = File(source);
  final dst = File(target);
  if (dst.existsSync() &&
      dst.lengthSync() == src.lengthSync() &&
      _sameBytes(src, dst)) {
    return;
  }
  final tmp = File('$target.$pid.${Random().nextInt(1 << 31)}.tmp');
  src.copySync(tmp.path);
  final chmod = Process.runSync('chmod', ['+x', tmp.path]);
  if (chmod.exitCode != 0) {
    tmp.deleteSync();
    stderr.write(chmod.stderr as String);
    exit(chmod.exitCode);
  }
  tmp.renameSync(target);
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
  final scratch = Directory('/tmp').createTempSync('rules_dart_snapshot.');
  try {
    // Every input is copied to its relative place, so the run needs only
    // relative paths.
    for (final c in copies) {
      _copyFile(c.value, '${scratch.path}/${c.key}');
    }
    for (final t in trees) {
      _copyTree(t.value, '${scratch.path}/${t.key}');
    }

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
        '--snapshot-kind=app-jit',
        '--snapshot=snapshot.jit',
        ...dartArgs,
      ],
      workingDirectory: scratch.path,
      environment: env,
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
      written.copySync(out.path);
    }
    return 0;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}

/// Copies every file under [from] to the same relative place under [to].
void _copyTree(String from, String to) {
  final source = Directory(from);
  for (final entity in source.listSync(recursive: true)) {
    if (entity is File) {
      final relative = entity.path.substring(source.path.length + 1);
      _copyFile(entity.path, '$to/$relative');
    }
  }
}

/// Copies [from] to [to], creating the parent directories of [to].
void _copyFile(String from, String to) {
  final parent = File(to).parent;
  parent.createSync(recursive: true);
  File(from).copySync(to);
}
