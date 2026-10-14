// Tests the planner of `kernel_module.dart`: which sources a module compiles, which it
// excludes and why, and what each compile is given. The compiler is a recorder, so no
// `kernel_worker` runs. The planner decides before it compiles, so nothing else is
// needed.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'kernel_module.dart' show ModuleCompiler, ModuleOutcome, compileModule;

const _prefix = 'org-dartlang-bazel:///';

/// The test's files: sources, module directories and sidecars, and the configs.
late Directory _root;

/// A compiler that records each request's arguments and succeeds.
class _Recorder implements ModuleCompiler {
  final List<List<String>> calls = [];

  @override
  Future<ModuleOutcome> run(List<String> args, List<Uint8List> inputs) async {
    calls.add(args);
    return const ModuleOutcome(0, '');
  }

  @override
  Future<void> close() async {}
}

/// The values that follow each `flag` in `args`, in order.
List<String> _valuesAfter(List<String> args, String flag) => [
  for (var i = 0; i + 1 < args.length; i++)
    if (args[i] == flag) args[i + 1],
];

/// A module's directory, which holds its `index.json`.
class _Scc {
  _Scc(this.dill, this.defines, this.imports);

  final String dill;
  final List<String> defines;
  final List<String> imports;
}

/// The outcome of one planned compile.
class _Result {
  _Result(this.code, this.calls, this.sidecar, this.index);

  final int code;
  final List<List<String>> calls;
  final String sidecar;
  final Map<String, dynamic> index;

  /// The excluded sources, by URI, with the reason each is excluded.
  Map<String, String> get excluded => {
    for (final line in const LineSplitter().convert(sidecar))
      if (line.isNotEmpty && !line.startsWith('#'))
        line.split('\t').first: line.split('\t').last,
  };

  /// The `defines` of each kernel the module wrote, in order.
  List<List<String>> get defines => [
    for (final scc in (index['sccs'] as List).cast<Map<String, dynamic>>())
      (scc['defines'] as List).cast<String>(),
  ];

  /// The `--source` URIs of each compile, in order.
  List<List<String>> get sourcesPerCall => [
    for (final call in calls) _valuesAfter(call, '--source'),
  ];
}

String _uri(String key) => '$_prefix$key';

void _write(String relative, String text) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text);
}

/// Writes a dependency module directory with `sccs`, and returns its path.
String _module(String name, List<_Scc> sccs) {
  _write(
    '$name/index.json',
    jsonEncode({
      'version': 1,
      'sccs': [
        for (final scc in sccs)
          {'dill': scc.dill, 'defines': scc.defines, 'imports': scc.imports},
      ],
    }),
  );
  return '${_root.path}/$name';
}

/// Writes the `.vm_excluded.txt` sidecar of a module, with `excluded` as its sources.
String _sidecar(String name, Map<String, String> excluded) {
  final lines = [
    for (final entry in excluded.entries) '${_uri(entry.key)}\t${entry.value}',
  ];
  _write('$name.vm_excluded.txt', lines.map((line) => '$line\n').join());
  return '${_root.path}/$name.vm_excluded.txt';
}

/// Plans and compiles one module named `name` from `sources`, which are keys under the
/// test's root (`pkg/lib/a.dart`). Returns what it wrote and what it asked the compiler.
Future<_Result> _compile(
  String name,
  List<String> sources, {
  List<String> inputKmods = const [],
  List<String> closureExcluded = const [],
  bool noDrop = false,
}) async {
  final output = '${_root.path}/out/$name';
  final excludedPath = '$output.vm_excluded.txt';
  final args = <String>[
    for (final source in sources) ...['--source', _uri(source)],
    '--output',
    output,
    '--excluded-output',
    excludedPath,
    '--packages-file',
    '${_root.path}/package_config.json',
    '--libraries-json',
    '${_root.path}/libraries.json',
    '--multi-root',
    _root.path,
    '--target',
    'vm',
    if (noDrop) '--no-drop',
    for (final dir in inputKmods) ...['--input-kmod', dir],
    for (final sidecar in closureExcluded) ...['--closure-excluded', sidecar],
  ];
  final recorder = _Recorder();
  final code = await compileModule(args, recorder, StringBuffer(), const []);
  final written = code == 0
      ? jsonDecode(File('$output/index.json').readAsStringSync())
            as Map<String, dynamic>
      : <String, dynamic>{'sccs': <dynamic>[]};
  return _Result(
    code,
    recorder.calls,
    code == 0 ? File(excludedPath).readAsStringSync() : '',
    written,
  );
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('kernel_module_test_');
    _write(
      'package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          for (final name in ['pkg', 'dep'])
            {'name': name, 'rootUri': '$_prefix$name', 'packageUri': 'lib/'},
        ],
      }),
    );
    // A VM with `async`, `core` and `io`, and no `html`.
    _write(
      'libraries.json',
      jsonEncode({
        'vm': {
          'libraries': {'async': {}, 'core': {}, 'io': {}},
        },
      }),
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('a library that imports only the VM compiles every source', () async {
    _write('pkg/lib/a.dart', "import 'dart:async';\nclass A {}\n");
    _write('pkg/lib/b.dart', "import 'a.dart';\nclass B {}\n");
    final result = await _compile('m', ['pkg/lib/a.dart', 'pkg/lib/b.dart']);
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.defines, [
      ['pkg/lib/a.dart'],
      ['pkg/lib/b.dart'],
    ]);
  });

  test(
    'a file that imports a library the VM lacks excludes its importers',
    () async {
      _write('pkg/lib/web.dart', "import 'dart:html';\nclass Web {}\n");
      _write('pkg/lib/uses_web.dart', "import 'web.dart';\n");
      _write('pkg/lib/plain.dart', "import 'dart:io';\nclass Plain {}\n");
      final result = await _compile('m', [
        'pkg/lib/web.dart',
        'pkg/lib/uses_web.dart',
        'pkg/lib/plain.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri('pkg/lib/web.dart'): 'dart:html is not a VM library',
        _uri('pkg/lib/uses_web.dart'):
            'imports ${_uri('pkg/lib/web.dart')}, which is excluded',
      });
      expect(result.defines, [
        ['pkg/lib/plain.dart'],
      ]);
    },
  );

  test('a file that imports a package the module does not have is excluded', () async {
    // `absent` is in no package config, as `json_annotation` is in no closure of
    // `_advanced_sources`.
    _write('pkg/lib/needs.dart', "import 'package:absent/absent.dart';\n");
    _write('pkg/lib/fine.dart', "import 'package:pkg/other.dart';\n");
    _write('pkg/lib/other.dart', 'class Other {}\n');
    final result = await _compile('m', [
      'pkg/lib/needs.dart',
      'pkg/lib/fine.dart',
      'pkg/lib/other.dart',
    ]);
    expect(result.code, 0);
    expect(result.excluded, {
      _uri(
        'pkg/lib/needs.dart',
      ): 'package:absent/absent.dart names a package this module does not have',
    });
    expect(result.defines, [
      ['pkg/lib/other.dart'],
      ['pkg/lib/fine.dart'],
    ]);
  });

  test(
    'a library whose part is not an input is excluded with its importers',
    () async {
      // `role.dart` declares a part that exists only on the wrapping library, as in
      // json_serializable's `_advanced_sources`.
      _write('pkg/lib/role.dart', "part 'role.g.dart';\nenum Role { a }\n");
      _write('pkg/lib/user.dart', "import 'role.dart';\n");
      _write('pkg/lib/extra.dart', 'class Extra {}\n');
      final result = await _compile('m', [
        'pkg/lib/role.dart',
        'pkg/lib/user.dart',
        'pkg/lib/extra.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, {
        _uri('pkg/lib/role.dart'):
            'its part role.g.dart is not an input of this module',
        _uri('pkg/lib/user.dart'):
            'imports ${_uri('pkg/lib/role.dart')}, which is excluded',
      });
      expect(result.defines, [
        ['pkg/lib/extra.dart'],
      ]);
    },
  );

  test(
    'a library and its part compile together when both are inputs',
    () async {
      _write('pkg/lib/role.dart', "part 'role.g.dart';\nenum Role { a }\n");
      _write('pkg/lib/role.g.dart', "part of 'role.dart';\nconst kRole = 1;\n");
      final result = await _compile('m', [
        'pkg/lib/role.dart',
        'pkg/lib/role.g.dart',
      ]);
      expect(result.code, 0);
      expect(result.excluded, isEmpty);
      expect(result.defines, [
        ['pkg/lib/role.dart', 'pkg/lib/role.g.dart'],
      ]);
    },
  );

  test('a source a dependency module defines is not compiled again', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final dep = _module('dep_module', [
      _Scc('0.dill', ['pkg/lib/shared.dart'], []),
    ]);
    final result = await _compile(
      'm',
      ['pkg/lib/shared.dart', 'pkg/lib/top.dart'],
      inputKmods: [dep],
    );
    expect(result.code, 0);
    expect(result.excluded, isEmpty);
    expect(result.sourcesPerCall, [
      [_uri('pkg/lib/top.dart')],
    ]);
    expect(_valuesAfter(result.calls.single, '--input-linked'), [
      '$dep/0.dill',
    ], reason: 'top links the kernel that defines shared');
  });

  test('a dependency excludes a file the dependent lists, so the dependent compiles its own', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    final dep = _module('dep_module', []);
    final sidecar = _sidecar('dep_module', {
      'pkg/lib/shared.dart': 'imports dart:html, which is not a VM library',
    });
    final result = await _compile(
      'm',
      ['pkg/lib/shared.dart'],
      inputKmods: [dep],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(
      result.excluded,
      isEmpty,
      reason: 'the module compiles its own copy',
    );
    expect(result.defines, [
      ['pkg/lib/shared.dart'],
    ]);
  });

  test('a file a dependency excludes, that a dependent only imports, excludes its importer', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final dep = _module('dep_module', []);
    final sidecar = _sidecar('dep_module', {
      'pkg/lib/shared.dart': 'its reason',
    });
    final result = await _compile(
      'm',
      ['pkg/lib/top.dart'],
      inputKmods: [dep],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(result.excluded, {
      _uri('pkg/lib/top.dart'): 'imports shared.dart, which is excluded',
    });
  });

  test('an excluded file that another module of the closure defines is not excluded', () async {
    _write('pkg/lib/shared.dart', 'class Shared {}\n');
    _write('pkg/lib/top.dart', "import 'shared.dart';\n");
    final excludes = _module('excludes', []);
    final defines = _module('defines', [
      _Scc('0.dill', ['pkg/lib/shared.dart'], []),
    ]);
    final sidecar = _sidecar('excludes', {'pkg/lib/shared.dart': 'its reason'});
    final result = await _compile(
      'm',
      ['pkg/lib/top.dart'],
      inputKmods: [excludes, defines],
      closureExcluded: [sidecar],
    );
    expect(result.code, 0);
    expect(
      result.excluded,
      isEmpty,
      reason: 'the defining module supplies the file',
    );
    expect(result.defines, [
      ['pkg/lib/top.dart'],
    ]);
    expect(_valuesAfter(result.calls.single, '--input-linked'), [
      '$defines/0.dill',
    ]);
  });

  test('an entry compiles an excluded file from source, unless a module defines it', () async {
    _write('pkg/lib/web.dart', 'class Web {}\n');
    _write('pkg/lib/defined.dart', 'class Defined {}\n');
    _write(
      'pkg/test/main_test.dart',
      "import 'package:pkg/web.dart';\nimport 'package:pkg/defined.dart';\n",
    );
    final excludes = _module('excludes', []);
    final defines = _module('defines', [
      _Scc('0.dill', ['pkg/lib/defined.dart'], []),
    ]);
    final sidecar = _sidecar('excludes', {
      'pkg/lib/web.dart': 'dart:html is not a VM library',
      'pkg/lib/defined.dart': 'dart:html is not a VM library',
    });
    final entry = await _compile(
      'entry',
      ['pkg/test/main_test.dart'],
      inputKmods: [excludes, defines],
      closureExcluded: [sidecar],
      noDrop: true,
    );
    expect(entry.code, 0);
    expect(
      entry.sourcesPerCall.single,
      containsAll([_uri('pkg/test/main_test.dart'), 'package:pkg/web.dart']),
    );
    expect(
      entry.sourcesPerCall.single,
      isNot(contains('package:pkg/defined.dart')),
      reason: 'the defining module supplies it',
    );
    expect(
      _valuesAfter(entry.calls.single, '--input-linked'),
      contains('$defines/0.dill'),
    );
  });

  test(
    'the same sources give the same kernels and index in any order',
    () async {
      _write('pkg/lib/b.dart', "import 'a.dart';\n");
      _write('pkg/lib/a.dart', 'class A {}\n');
      final first = await _compile('m1', ['pkg/lib/b.dart', 'pkg/lib/a.dart']);
      final second = await _compile('m2', ['pkg/lib/a.dart', 'pkg/lib/b.dart']);
      expect(first.defines, second.defines);
      expect(first.index, second.index);
    },
  );
}
