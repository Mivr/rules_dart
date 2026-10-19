// Tests for the per-entry `Changelog:` rules in `check_commit_messages.dart`.
import 'package:test/test.dart';

import 'check_commit_messages.dart';

void main() {
  group('changelogProblems accepts valid entries', () {
    test('a `code`-leading entry with balanced backticks', () {
      expect(changelogProblems(['`foo` does the thing']), isEmpty);
    });

    test('plain apostrophes', () {
      expect(
        changelogProblems([
          "Don't drop the caller's name",
          '`flutter_bazel run` finds devices that answer mDNS slowly',
        ]),
        isEmpty,
      );
    });

    test('an entry at the length limit', () {
      expect(changelogProblems(['A' * 100]), isEmpty);
    });

    test('an even number of backticks', () {
      expect(changelogProblems(['Adds `a` beside `b`']), isEmpty);
    });

    test('skip entries, however many', () {
      expect(changelogProblems(['skip', 'skip']), isEmpty);
    });
  });

  group('changelogProblems rejects each rule', () {
    test('an entry over the length limit', () {
      final entry = 'A' * 101;
      expect(changelogProblems([entry]), [
        'Changelog entry over 100 chars: $entry',
      ]);
    });

    test('an entry that ends with a period', () {
      expect(changelogProblems(['Adds a thing.']), [
        'Changelog entry ends with a period: Adds a thing.',
      ]);
    });

    test('an entry that does not start with a capital or `code`', () {
      expect(changelogProblems(['adds a thing']), [
        'Changelog entry must start with a capital letter or `code`: '
            'adds a thing',
      ]);
    });

    test('a backslash-escaped single quote', () {
      final entry = r"Restore the caller\'s name";
      expect(changelogProblems([entry]), [
        'Changelog entry contains shell-quoting escapes: $entry',
      ]);
    });

    test('a backslash-escaped double quote', () {
      final entry = r'Adds a \"quoted\" word';
      expect(changelogProblems([entry]), [
        'Changelog entry contains shell-quoting escapes: $entry',
      ]);
    });

    test('the quoted-quote shell artifact', () {
      final entry = """Restore the caller'"'"'s name""";
      expect(changelogProblems([entry]), [
        'Changelog entry contains shell-quoting escapes: $entry',
      ]);
    });

    test('an odd number of backticks', () {
      expect(changelogProblems(['Adds a `code span']), [
        'Changelog entry has unbalanced backticks: Adds a `code span',
      ]);
    });

    test('the same entry twice', () {
      expect(changelogProblems(['Adds a thing', 'Adds a thing']), [
        'Changelog entry is a duplicate of an earlier one: Adds a thing',
      ]);
    });

    test('every failing rule, in order', () {
      expect(changelogProblems(['adds a `thing.']), [
        'Changelog entry ends with a period: adds a `thing.',
        'Changelog entry must start with a capital letter or `code`: '
            'adds a `thing.',
        'Changelog entry has unbalanced backticks: adds a `thing.',
      ]);
    });
  });
}
