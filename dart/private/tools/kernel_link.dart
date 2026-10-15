// Links an executable's kernel from the kernels its entry reaches, or a shared
// base kernel from `--seed-module` directories. Run by `kernel_link_action` in
// `dart/private/dart_kernel.bzl`.
//
// The arguments are a params file holding optional flags (`--write-keys <path>`,
// `--base-keys <path>`, repeatable `--seed-module <dir>`), `<output>`, the entry
// module's directory (when `--seed-module` is not used), and then each dependency
// module's directory, one per line. Each directory holds an `index.json` that
// lists its kernels: the file of each, the keys of the libraries it defines, and
// the keys it imports. The entry's index names the entry kernel and what the
// entry imports.
//
// The link walks the imports from the entry (or seed modules), and writes only
// the kernels it reaches. The entry kernel comes first, then each dependency
// kernel after every kernel it imports. When `--base-keys <path>` is passed, any
// dependency kernel whose `<dir>:<dill>` key is already in the base kernel is
// skipped from the output (while still traversed during reachability so
// transitive imports through base modules are discovered).
//
// The entry comes first because the VM runs the `main` of the first component that
// has one, and a dependency's component can have a `main` of its own: a library that
// defines `main` for its CLI, say. Linking the entry last ran that library's `main`
// instead of the test's, and the test hung. With the entry first the test's `main` runs.
//
// The VM loads a file of concatenated kernels as one program. This is a compiled
// `dart_binary` of the exec platform, so the link runs without the SDK as an input,
// and a `dart_test` can name it as an executable attribute.

import 'dart:convert';
import 'dart:io';

/// A kernel an index lists: its file, its `<dir>:<dill>` key, and what it defines and imports.
class _Kernel {
  _Kernel(this.path, this.key, this.defines, this.imports);

  final String path;
  final String key;
  final List<String> defines;
  final List<String> imports;
}

Future<void> main(List<String> args) async {
  final rawArgs = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      rawArgs.addAll(await File(arg.substring(1)).readAsLines());
    } else {
      rawArgs.add(arg);
    }
  }
  await _linkOne(rawArgs);
}

Future<void> _linkOne(List<String> rawArgs) async {
  String? writeKeysPath;
  String? baseKeysPath;
  String? platform;
  final seedModules = <String>[];
  final paths = <String>[];
  for (var i = 0; i < rawArgs.length; i++) {
    final arg = rawArgs[i];
    if (arg.isEmpty) continue;
    if (arg == '--write-keys') {
      writeKeysPath = rawArgs[++i];
    } else if (arg == '--base-keys') {
      baseKeysPath = rawArgs[++i];
    } else if (arg == '--seed-module') {
      seedModules.add(rawArgs[++i]);
    } else if (arg == '--platform' && i + 1 < rawArgs.length) {
      platform = rawArgs[++i];
    } else if (arg.startsWith('--platform=')) {
      platform = arg.substring('--platform='.length);
    } else {
      paths.add(arg);
    }
  }
  final output = paths[0];
  final _Kernel? entry;
  final Iterable<String> depDirs;
  if (seedModules.isEmpty) {
    entry = (await _kernelsOf(paths[1])).single;
    depDirs = paths.skip(2);
  } else {
    entry = null;
    depDirs = paths.skip(1);
  }

  // The kernel that defines each key. Each key has one definition across a closure, so
  // which one `putIfAbsent` keeps does not matter; a repeat is reported below.
  final owner = <String, _Kernel>{};
  final kernelsByDir = <String, List<_Kernel>>{};
  for (final dir in <String>{...seedModules, ...depDirs}) {
    final kernels = await _kernelsOf(dir);
    kernelsByDir[dir] = kernels;
    for (final kernel in kernels) {
      for (final key in kernel.defines) {
        owner.putIfAbsent(key, () => kernel);
      }
    }
  }

  // A postorder walk: a kernel is written after each kernel it imports.
  final order = <_Kernel>[];
  final visited = <_Kernel>{};
  void visit(_Kernel kernel) {
    if (!visited.add(kernel)) return;
    for (final key in ([...kernel.imports]..sort())) {
      final dependency = owner[key];
      if (dependency != null) visit(dependency);
    }
    order.add(kernel);
  }

  if (entry != null) {
    for (final key in ([...entry.imports]..sort())) {
      final dependency = owner[key];
      if (dependency != null) visit(dependency);
    }
  } else {
    for (final seedDir in seedModules) {
      final kernels = kernelsByDir[seedDir]!;
      // In `package:test` (`test_library.kmod`), `lib/src/executable.dart` imports
      // the CLI runner (`analyzer`, `shelf`, `watcher`), which no VM test isolate
      // imports. Seed only the VM test API entrypoints so `test.base.dill` stays
      // ~2.0 MB instead of ~18.8 MB; any other SCC a test imports is simply not in
      // `base.keys` and is emitted in that test's delta `.dill`.
      final isPackageTest = kernels.any(
        (k) => k.defines.any((d) => d.endsWith('/lib/bootstrap/vm.dart')),
      );
      for (final kernel in kernels) {
        if (isPackageTest) {
          final isTestApi = kernel.defines.any(
            (d) =>
                d.endsWith('/lib/test.dart') ||
                d.endsWith('/lib/scaffolding.dart') ||
                d.endsWith('/lib/expect.dart') ||
                d.endsWith('/lib/bootstrap/vm.dart') ||
                d.endsWith('/lib/fake.dart'),
          );
          if (!isTestApi) continue;
        }
        visit(kernel);
      }
    }
  }

  // The module planner gives each library one kernel, so no two kernels that are
  // linked define the same key. The VM would load both, and the frontend refuses a
  // kernel set that defines a library twice, so a repeat is a bug to report, not link.
  final linked = [if (entry != null) entry, ...order];
  final definedBy = <String, _Kernel>{};
  for (final kernel in linked) {
    for (final key in kernel.defines) {
      final other = definedBy[key];
      if (other != null) {
        stderr.writeln(
          'kernel_link: $key is defined by ${other.path} and ${kernel.path}.',
        );
        exitCode = 1;
        return;
      }
      definedBy[key] = kernel;
    }
  }

  final baseKeys = <String>{};
  if (baseKeysPath != null) {
    for (final line in await File(baseKeysPath).readAsLines()) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) baseKeys.add(trimmed);
    }
  }

  final emitted = [
    if (entry != null) entry,
    for (final kernel in order)
      if (!baseKeys.contains(kernel.key)) kernel,
  ];

  final sink = File(output).openWrite();
  if (platform != null) {
    await sink.addStream(File(platform).openRead());
  }
  for (final kernel in emitted) {
    await sink.addStream(File(kernel.path).openRead());
  }
  await sink.close();

  if (writeKeysPath != null) {
    await File(writeKeysPath)
        .writeAsString(emitted.map((k) => '${k.key}\n').join());
  }
}

/// The kernels a module directory's index lists. Their paths are the directory joined
/// to each file name, as the compile wrote them.
Future<List<_Kernel>> _kernelsOf(String dir) async {
  final json = jsonDecode(
    await File('$dir/index.json').readAsString(),
  ) as Map<String, dynamic>;
  return [
    for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>())
      _Kernel(
        '$dir/${scc['dill']}',
        '$dir:${scc['dill']}',
        (scc['defines'] as List).cast<String>(),
        (scc['imports'] as List).cast<String>(),
      ),
  ];
}
