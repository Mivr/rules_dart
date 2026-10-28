import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Reads a merged cycle member's `pubspec.yaml` from runfiles.
///
/// `dio` and `dio_web_adapter` share one generated repository because they
/// depend on each other. Each member keeps its own package root, so its
/// `pubspec.yaml` reaches a dependent test through the merged library's
/// `data`, not through the root package.
void readPubspec(Runfiles runfiles, String path, String name) {
  final found = runfiles.rlocation(path);
  final pubspec = File(found);
  if (!pubspec.existsSync()) {
    stderr.writeln('The merged member pubspec.yaml is not in runfiles: $found');
    exit(1);
  }
  final content = pubspec.readAsStringSync();
  if (!content.contains('name: $name')) {
    stderr.writeln('Unexpected pubspec content at $found:\n$content');
    exit(1);
  }
}

void main() {
  final runfiles = Runfiles.create();
  const repo = 'ai_rules_dart++pub+dart_pub__scc__dio__dio_web_adapter';
  readPubspec(runfiles, '$repo/dio/pubspec.yaml', 'dio');
  readPubspec(
    runfiles,
    '$repo/dio_web_adapter/pubspec.yaml',
    'dio_web_adapter',
  );
}
