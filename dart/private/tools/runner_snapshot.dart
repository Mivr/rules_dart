// Build-action runner for the app-JIT snapshot of a `package:test` runner.
//
// The runner is a large kernel that the VM compiles again on every test run,
// which is most of a test's startup. An app-JIT snapshot of it starts faster.
// The snapshot is taken by running one real precompiled test under the runner
// (the training run), so it holds the code a test actually takes. Pure Dart (no
// shell) so the action is portable to Windows.
import 'dart:io';

void main(List<String> args) {
  String? dart;
  String? runner;
  String? precompiled;
  String? testPath;
  String? snapshot;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--dart':
        dart = args[++i];
      case '--runner':
        runner = args[++i];
      case '--precompiled':
        precompiled = args[++i];
      case '--test-path':
        testPath = args[++i];
      case '--snapshot':
        snapshot = args[++i];
      default:
        stderr.writeln('runner_snapshot: unknown argument ${args[i]}');
        exit(64);
    }
  }
  if (dart == null ||
      runner == null ||
      precompiled == null ||
      testPath == null ||
      snapshot == null) {
    stderr.writeln(
      'runner_snapshot: --dart, --runner, --precompiled, --test-path, and '
      '--snapshot are required',
    );
    exit(64);
  }

  final out = File(snapshot);
  // The reporter's output and the config path live in a scratch directory
  // beside the snapshot, removed once the training run is over.
  final scratch = Directory(out.absolute.parent.path)
      .createTempSync('runner_snapshot.');
  // The reporter is the launcher's, so the training run takes the code paths a
  // real test run takes.
  final result = _train(dart, scratch, [
    '--enable-asserts',
    '--snapshot-kind=app-jit',
    '--snapshot=${out.absolute.path}',
    runner,
    '--precompiled=$precompiled',
    '--reporter=expanded',
    '--timeout=60s',
    '--file-reporter=json:${scratch.path}/results.json',
    testPath,
  ]);

  // Bazel echoes any action output, so a clean run stays silent.
  if (result.exitCode != 0) {
    stdout.write(result.stdout as String);
    stderr.write(result.stderr as String);
    exit(result.exitCode);
  }
  if (!out.existsSync()) {
    stderr.writeln(
      'runner_snapshot: the training run of $testPath wrote no snapshot to '
      '${out.path}',
    );
    exit(1);
  }
}

/// Runs the training test under the runner, then removes [scratch] whatever the
/// outcome. `exit` is not called in here: it would skip the cleanup.
ProcessResult _train(String dart, Directory scratch, List<String> args) {
  try {
    return Process.runSync(
      dart,
      args,
      environment: {
        // A path that does not exist: a developer's own `DartTest.yaml` must not
        // change what the snapshot is trained on.
        'DART_TEST_CONFIG': '${scratch.path}/no_global_config/DartTest.yaml',
      },
    );
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
