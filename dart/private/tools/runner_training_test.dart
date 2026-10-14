// The test the `package:test` runner is trained on: `dart_test_runner_snapshot`
// runs it once under the runner and keeps the app-JIT snapshot that run wrote.
// It stays small, but touches the runner's usual paths: a group, `setUp`, and
// a couple of `expect`s.
import 'package:test/test.dart';

void main() {
  group('runner training', () {
    late List<int> values;

    setUp(() {
      values = [1, 2, 3];
    });

    test('compares a list', () {
      expect(values, hasLength(3));
      expect(values.first, equals(1));
    });

    test('compares a string', () {
      expect('bazel', contains('az'));
    });
  });
}
