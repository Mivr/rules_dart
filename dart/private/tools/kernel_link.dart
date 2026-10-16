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
//
// Supports both one-shot execution (with `@flagfile` expansion) and Bazel's
// `--persistent_worker` binary protobuf protocol over stdin/stdout, caching
// parsed `index.json` manifests, `--base-keys` sets, and `.dill` bytes across
// requests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A kernel an index lists: its file, its `<dir>:<dill>` key, and what it defines and imports.
class _Kernel {
  _Kernel(this.path, this.key, this.defines, this.imports);

  final String path;
  final String key;
  final List<String> defines;
  final List<String> imports;
}

class _CachedEntry<T> {
  _CachedEntry(this.value, this.digest, this.size, this.modifiedMicros);

  final T value;
  final Uint8List? digest;
  final int size;
  final int modifiedMicros;
}

class _KernelLinkCache {
  final _indexCache = <String, _CachedEntry<List<_Kernel>>>{};
  final _baseKeysCache = <String, _CachedEntry<Set<String>>>{};
  final _dillCache = <String, _CachedEntry<Uint8List>>{};
  int _dillBytesTotal = 0;
  static const int _maxDillCacheBytes = 128 * 1024 * 1024;

  static bool _sameDigest(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<_Kernel> kernelsOf(String dir, Map<String, Uint8List>? inputs) {
    final indexPath = '$dir/index.json';
    final digest = inputs?[indexPath];
    final cached = _indexCache[dir];
    if (cached != null) {
      if (digest != null &&
          cached.digest != null &&
          digest.isNotEmpty &&
          _sameDigest(digest, cached.digest!)) {
        return cached.value;
      }
      final stat = File(indexPath).statSync();
      if (stat.size == cached.size &&
          stat.modified.microsecondsSinceEpoch == cached.modifiedMicros) {
        return cached.value;
      }
    }
    final file = File(indexPath);
    final stat = file.statSync();
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final kernels = [
      for (final scc in (json['sccs'] as List).cast<Map<String, dynamic>>())
        _Kernel(
          '$dir/${scc['dill']}',
          '$dir:${scc['dill']}',
          (scc['defines'] as List).cast<String>(),
          (scc['imports'] as List).cast<String>(),
        ),
    ];
    _indexCache[dir] = _CachedEntry(
      kernels,
      digest,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
    );
    return kernels;
  }

  Set<String> baseKeysOf(String path, Map<String, Uint8List>? inputs) {
    final digest = inputs?[path];
    final cached = _baseKeysCache[path];
    if (cached != null) {
      if (digest != null &&
          cached.digest != null &&
          digest.isNotEmpty &&
          _sameDigest(digest, cached.digest!)) {
        return cached.value;
      }
      final stat = File(path).statSync();
      if (stat.size == cached.size &&
          stat.modified.microsecondsSinceEpoch == cached.modifiedMicros) {
        return cached.value;
      }
    }
    final file = File(path);
    final stat = file.statSync();
    final keys = <String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) keys.add(trimmed);
    }
    _baseKeysCache[path] = _CachedEntry(
      keys,
      digest,
      stat.size,
      stat.modified.microsecondsSinceEpoch,
    );
    return keys;
  }

  Uint8List dillBytesOf(String path, Map<String, Uint8List>? inputs) {
    final digest = inputs?[path];
    final cached = _dillCache[path];
    if (cached != null) {
      if (digest != null &&
          cached.digest != null &&
          digest.isNotEmpty &&
          _sameDigest(digest, cached.digest!)) {
        return cached.value;
      }
      final stat = File(path).statSync();
      if (stat.size == cached.size &&
          stat.modified.microsecondsSinceEpoch == cached.modifiedMicros) {
        return cached.value;
      }
      _dillBytesTotal -= cached.value.length;
      _dillCache.remove(path);
    }
    final file = File(path);
    final stat = file.statSync();
    final bytes = file.readAsBytesSync();
    if (bytes.length <= 16 * 1024 * 1024) {
      while (_dillBytesTotal + bytes.length > _maxDillCacheBytes &&
          _dillCache.isNotEmpty) {
        final oldestKey = _dillCache.keys.first;
        final removed = _dillCache.remove(oldestKey)!;
        _dillBytesTotal -= removed.value.length;
      }
      _dillCache[path] = _CachedEntry(
        bytes,
        digest,
        stat.size,
        stat.modified.microsecondsSinceEpoch,
      );
      _dillBytesTotal += bytes.length;
    }
    return bytes;
  }
}

List<String> _expandParamFiles(List<String> args) {
  final out = <String>[];
  for (final arg in args) {
    if (arg.startsWith('@')) {
      out.addAll(File(arg.substring(1)).readAsLinesSync());
    } else {
      out.add(arg);
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final expanded = _expandParamFiles(args);
  if (expanded.contains('--persistent_worker')) {
    await _runPersistentWorker();
    return;
  }
  final cache = _KernelLinkCache();
  final code = _linkOne(expanded, cache: cache, errSink: stderr);
  if (code != 0) exit(code);
}

Future<void> _runPersistentWorker() async {
  final cache = _KernelLinkCache();
  await for (final bytes in _Frames(stdin)) {
    final request = _WorkRequest.read(bytes);
    if (request.cancel) continue;
    final output = StringBuffer();
    var code = 1;
    try {
      final expanded = _expandParamFiles(request.arguments);
      code = _linkOne(
        expanded,
        cache: cache,
        inputs: request.inputs,
        errSink: output,
      );
    } on Object catch (e, st) {
      output
        ..writeln('kernel_link: unhandled exception: $e')
        ..writeln(st);
      code = 1;
    }
    stdout.add(
      _WorkResponse(
        exitCode: code,
        output: output.toString(),
        requestId: request.requestId,
      ).write(),
    );
    await stdout.flush();
  }
}

int _linkOne(
  List<String> rawArgs, {
  required _KernelLinkCache cache,
  Map<String, Uint8List>? inputs,
  required StringSink errSink,
}) {
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
    entry = cache.kernelsOf(paths[1], inputs).single;
    depDirs = paths.skip(2);
  } else {
    entry = null;
    depDirs = paths.skip(1);
  }

  final owner = <String, _Kernel>{};
  final kernelsByDir = <String, List<_Kernel>>{};
  for (final dir in <String>{...seedModules, ...depDirs}) {
    final kernels = cache.kernelsOf(dir, inputs);
    kernelsByDir[dir] = kernels;
    for (final kernel in kernels) {
      for (final key in kernel.defines) {
        owner.putIfAbsent(key, () => kernel);
      }
    }
  }

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

  final linked = [if (entry != null) entry, ...order];
  final definedBy = <String, _Kernel>{};
  for (final kernel in linked) {
    for (final key in kernel.defines) {
      final other = definedBy[key];
      if (other != null) {
        errSink.writeln(
          'kernel_link: $key is defined by ${other.path} and ${kernel.path}.',
        );
        return 1;
      }
      definedBy[key] = kernel;
    }
  }

  final baseKeys = baseKeysPath != null
      ? cache.baseKeysOf(baseKeysPath, inputs)
      : const <String>{};

  final emitted = [
    if (entry != null) entry,
    for (final kernel in order)
      if (!baseKeys.contains(kernel.key)) kernel,
  ];

  final outBuilder = BytesBuilder(copy: false);
  if (platform != null) {
    outBuilder.add(cache.dillBytesOf(platform, inputs));
  }
  for (final kernel in emitted) {
    outBuilder.add(cache.dillBytesOf(kernel.path, inputs));
  }
  File(output).writeAsBytesSync(outBuilder.takeBytes());

  if (writeKeysPath != null) {
    File(writeKeysPath)
        .writeAsStringSync(emitted.map((k) => '${k.key}\n').join());
  }
  return 0;
}

final class _WorkRequest {
  _WorkRequest({
    required this.arguments,
    required this.inputs,
    required this.requestId,
    required this.cancel,
  });

  factory _WorkRequest.read(Uint8List bytes) {
    final arguments = <String>[];
    final inputs = <String, Uint8List>{};
    var requestId = 0;
    var cancel = false;
    final r = _Reader(bytes);
    while (!r.isDone) {
      final tag = r.varint();
      switch (tag >> 3) {
        case 1:
          arguments.add(r.string());
        case 2:
          final nested = r.submessage();
          var path = '';
          var digest = Uint8List(0);
          while (!nested.isDone) {
            final inputTag = nested.varint();
            switch (inputTag >> 3) {
              case 1:
                path = nested.string();
              case 2:
                digest = nested.bytes();
              default:
                nested.skip(inputTag & 7);
            }
          }
          if (path.isNotEmpty) {
            inputs[path] = digest;
          }
        case 3:
          requestId = r.varint();
        case 4:
          cancel = r.varint() != 0;
        default:
          r.skip(tag & 7);
      }
    }
    return _WorkRequest(
      arguments: arguments,
      inputs: inputs,
      requestId: requestId,
      cancel: cancel,
    );
  }

  final List<String> arguments;
  final Map<String, Uint8List> inputs;
  final int requestId;
  final bool cancel;
}

final class _WorkResponse {
  const _WorkResponse({
    required this.exitCode,
    required this.output,
    required this.requestId,
  });

  final int exitCode;
  final String output;
  final int requestId;

  Uint8List write() {
    final body = _Writer();
    if (exitCode != 0) {
      body
        ..varint((1 << 3) | 0)
        ..varint(exitCode);
    }
    if (output.isNotEmpty) {
      final utf8Bytes = utf8.encode(output);
      body
        ..varint((2 << 3) | 2)
        ..varint(utf8Bytes.length)
        ..raw(utf8Bytes);
    }
    if (requestId != 0) {
      body
        ..varint((3 << 3) | 0)
        ..varint(requestId);
    }
    final payload = body.takeBytes();
    final frame = _Writer()
      ..varint(payload.length)
      ..raw(payload);
    return frame.takeBytes();
  }
}

final class _Frames extends Stream<Uint8List> {
  _Frames(this._source);

  final Stream<List<int>> _source;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    var buf = Uint8List(0);
    late final StreamSubscription<List<int>> sub;
    sub = _source.listen(
      (chunk) {
        final merged = Uint8List(buf.length + chunk.length);
        merged.setRange(0, buf.length, buf);
        merged.setRange(buf.length, merged.length, chunk);
        buf = merged;
        while (true) {
          var len = 0;
          var shift = 0;
          var pos = 0;
          while (true) {
            if (pos >= buf.length) return;
            final b = buf[pos++];
            len |= (b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
          }
          if (buf.length < pos + len) return;
          controller.add(Uint8List.sublistView(buf, pos, pos + len));
          buf = Uint8List.sublistView(buf, pos + len);
        }
      },
      onError: controller.addError,
      onDone: controller.close,
      cancelOnError: cancelOnError,
    );
    controller
      ..onPause = sub.pause
      ..onResume = sub.resume
      ..onCancel = sub.cancel;
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

final class _Reader {
  _Reader(this._buf);

  final Uint8List _buf;
  int _pos = 0;

  bool get isDone => _pos >= _buf.length;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) return result;
      shift += 7;
    }
  }

  Uint8List bytes() {
    final len = varint();
    final slice = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return slice;
  }

  String string() => utf8.decode(bytes());

  _Reader submessage() => _Reader(bytes());

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        varint();
      case 1:
        _pos += 8;
      case 2:
        _pos += varint();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wire type: $wireType');
    }
  }
}

final class _Writer {
  final _buf = BytesBuilder(copy: false);

  void varint(int value) {
    var v = value;
    while (v < 0 || v >= 0x80) {
      _buf.addByte((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
    _buf.addByte(v);
  }

  void raw(List<int> bytes) => _buf.add(bytes);

  Uint8List takeBytes() => _buf.takeBytes();
}
