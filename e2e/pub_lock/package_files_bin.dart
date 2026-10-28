import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// Reads a transitive pub spoke's `pubspec.yaml` from a binary's runfiles.
void main() {
  final runfiles = Runfiles.create();
  final path = runfiles.rlocation('path/pubspec.yaml');
  final pubspec = File(path);
  if (!pubspec.existsSync()) {
    stderr.writeln(
      'The transitive pub spec is not in the binary runfiles: $path',
    );
    exit(1);
  }
  if (!pubspec.readAsStringSync().contains('name: path')) {
    stderr.writeln('Unexpected pubspec content at $path');
    exit(1);
  }
  stdout.writeln('found $path');
}
