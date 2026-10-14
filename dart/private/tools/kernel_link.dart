// Links an executable's kernel from the kernels its entry reaches. Run by
// `kernel_link_action` in `dart/private/dart_kernel.bzl`.
//
// The arguments are a params file holding `<output>`, the entry module's directory,
// and then each dependency module's directory, one per line. Each directory holds an
// `index.json` that lists its kernels: the file of each, the keys of the libraries it
// defines, and the keys it imports. The entry's index names the entry kernel and what
// the entry imports.
//
// The link walks the imports from the entry, and writes only the kernels it reaches,
// each after every kernel it imports, and the entry kernel last. A kernel that nothing
// reaches is not written, so the VM never loads it. The walk visits imports in sorted
// order, so the same indexes always link to the same bytes.
//
// The VM loads a file of concatenated kernels as one program. This is a compiled
// `dart_binary` of the exec platform, so the link runs without the SDK as an input,
// and a `dart_test` can name it as an executable attribute.

import 'dart:convert';
import 'dart:io';

/// A kernel an index lists: its file, and what it defines and imports.
class _Kernel {
  _Kernel(this.path, this.defines, this.imports);

  final String path;
  final List<String> defines;
  final List<String> imports;
}

Future<void> main(List<String> args) async {
  final paths = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      paths.addAll(await File(arg.substring(1)).readAsLines());
    } else {
      paths.add(arg);
    }
  }
  final output = paths[0];
  final entry = (await _kernelsOf(paths[1])).single;

  // The kernel that defines each key. A key is defined once, so the first wins.
  final owner = <String, _Kernel>{};
  for (final dir in paths.skip(2)) {
    for (final kernel in await _kernelsOf(dir)) {
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

  for (final key in ([...entry.imports]..sort())) {
    final dependency = owner[key];
    if (dependency != null) visit(dependency);
  }
  order.add(entry);

  final sink = File(output).openWrite();
  for (final kernel in order) {
    await sink.addStream(File(kernel.path).openRead());
  }
  await sink.close();
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
        (scc['defines'] as List).cast<String>(),
        (scc['imports'] as List).cast<String>(),
      ),
  ];
}
