import 'package:test/test.dart';

import 'check_commit_messages.dart';

void main() {
  group('checkChangelogEntries', () {
    test('accepts a valid entry', () {
      expect(checkChangelogEntries(['`foo` does bar']), isEmpty);
    });

    test('accepts plain apostrophes', () {
      expect(checkChangelogEntries(["Don't do X", "Caller's thing"]), isEmpty);
    });

    group('length', () {
      test('accepts exactly 100 chars', () {
        expect(checkChangelogEntries(['A' * 100]), isEmpty);
      });
      test('rejects over 100 chars', () {
        final entry = 'A' * 101;
        expect(
          checkChangelogEntries([entry]),
          contains('Changelog entry over 100 chars: $entry'),
        );
      });
    });

    group('trailing period', () {
      test('accepts no trailing period', () {
        expect(checkChangelogEntries(['Foo bar']), isEmpty);
      });
      test('rejects trailing period', () {
        expect(
          checkChangelogEntries(['Foo bar.']),
          contains('Changelog entry ends with a period: Foo bar.'),
        );
      });
    });

    group('start character', () {
      test('accepts capital letter', () {
        expect(checkChangelogEntries(['Foo bar']), isEmpty);
      });
      test('accepts backtick', () {
        expect(checkChangelogEntries(['`foo` bar']), isEmpty);
      });
      test('rejects lowercase start', () {
        expect(
          checkChangelogEntries(['foo bar']),
          contains(
            'Changelog entry must start with a capital letter or `code`: foo bar',
          ),
        );
      });
    });

    group('shell-quoting artifact', () {
      test('rejects single-quote artifact', () {
        final entry = "Caller'\\''s thing";
        expect(
          checkChangelogEntries([entry]),
          contains('Changelog entry contains a shell-quoting artifact: $entry'),
        );
      });
      test('rejects double-quote artifact', () {
        final entry = "'" + '"' + "'" + '"' + "'";
        final full = 'Foo $entry bar';
        expect(
          checkChangelogEntries([full]),
          contains('Changelog entry contains a shell-quoting artifact: $full'),
        );
      });
      test('rejects backslash followed by quote', () {
        final entry = 'Foo ' + r"\'" + ' bar';
        expect(
          checkChangelogEntries([entry]),
          contains('Changelog entry contains a shell-quoting artifact: $entry'),
        );
      });
      test('accepts plain apostrophe', () {
        expect(checkChangelogEntries(["Don't"]), isEmpty);
      });
    });

    group('backticks', () {
      test('accepts balanced backticks', () {
        expect(checkChangelogEntries(['`foo` bar']), isEmpty);
      });
      test('rejects unbalanced backticks', () {
        final entry = 'Foo `bar';
        expect(
          checkChangelogEntries([entry]),
          contains('Changelog entry has unbalanced backticks: $entry'),
        );
      });
    });

    group('duplicate', () {
      test('accepts distinct entries', () {
        expect(checkChangelogEntries(['Foo bar', 'Baz qux']), isEmpty);
      });
      test('rejects duplicate entry', () {
        final entry = 'Foo bar';
        expect(
          checkChangelogEntries([entry, entry]),
          contains('Changelog entry is a duplicate: $entry'),
        );
      });
    });

    test('skip is exempt', () {
      expect(checkChangelogEntries(['skip', 'skip']), isEmpty);
    });
  });
}
