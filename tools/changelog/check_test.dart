// Tests for the per-entry `Changelog:` rules in check_commit_messages.dart.
import 'dart:io';

import 'check_commit_messages.dart' as checker;

var _failures = 0;

void _expectClean(List<String> entries, String label) {
  final problems = checker.checkEntries(entries);
  if (problems.isNotEmpty) {
    _failures++;
    stderr.writeln('FAIL $label: expected clean, got $problems');
  } else {
    stdout.writeln('PASS $label');
  }
}

void _expectProblem(
  List<String> entries,
  String entry,
  String ruleFragment,
  String label,
) {
  final problems = checker.checkEntries(entries);
  final match = problems.any(
    (p) => p.contains(ruleFragment) && p.contains(entry),
  );
  if (!match) {
    _failures++;
    stderr.writeln(
      'FAIL $label: expected a problem naming "$ruleFragment" '
      'quoting "$entry", got $problems',
    );
  } else {
    stdout.writeln('PASS $label');
  }
}

void main() {
  // Length.
  _expectClean([('A' + 'x' * 99)], 'length accepts 100 chars');
  _expectProblem(
    [('A' + 'x' * 100)],
    'A' + 'x' * 100,
    'over 100 chars',
    'length rejects 101 chars',
  );

  // Trailing period.
  _expectClean(['Add support for widgets'], 'period accepts no period');
  _expectProblem(
    ['Add support for widgets.'],
    'Add support for widgets.',
    'ends with a period',
    'period rejects trailing period',
  );

  // Start character.
  _expectClean(['Add support for widgets'], 'start accepts capital');
  _expectClean([
    '`flutter_ios_extension` builds iOS app extensions',
  ], 'start accepts backtick');
  _expectProblem(
    ['add support for widgets'],
    'add support for widgets',
    'must start with a capital',
    'start rejects lowercase',
  );
  _expectProblem(
    ['123 things'],
    '123 things',
    'must start with a capital',
    'start rejects digit',
  );

  // Plain apostrophes stay valid.
  _expectClean(["Don't break things"], 'apostrophe accepts Don\'t');
  _expectClean(["Fix caller's bug"], 'apostrophe accepts caller\'s');

  // Shell-quoting artifacts.
  _expectProblem(
    [r"Fix caller'\''s bug"],
    r"Fix caller'\''s bug",
    'shell-quoting artifact',
    'shell rejects quoted artifact',
  );
  _expectProblem(
    ['Add \'"\'"\' quoting'],
    '\'"\'"\'',
    'shell-quoting artifact',
    'shell rejects double-quote artifact',
  );
  _expectProblem(
    [r"Add foo\'s bar"],
    r"Add foo\'s bar",
    'shell-quoting artifact',
    'shell rejects backslash-quote',
  );
  _expectProblem(
    [r'Add foo\"bar'],
    r'Add foo\"bar',
    'shell-quoting artifact',
    'shell rejects backslash-double-quote',
  );

  // Unbalanced backticks.
  _expectClean(['Add support for widgets'], 'backticks accepts zero');
  _expectClean(['`foo` and `bar` work'], 'backticks accepts balanced');
  _expectProblem(
    ['Add `foo support'],
    'Add `foo support',
    'unbalanced backticks',
    'backticks rejects single',
  );
  _expectProblem(
    ['`foo` and `bar'],
    '`foo` and `bar',
    'unbalanced backticks',
    'backticks rejects three',
  );

  // Duplicates.
  _expectClean([
    'Add one thing',
    'Add another thing',
  ], 'duplicate accepts distinct');
  _expectProblem(
    ['Add one thing', 'Add one thing'],
    'Add one thing',
    'duplicated',
    'duplicate rejects repeat',
  );

  // Skip entries are exempt from every per-entry rule.
  _expectClean(['skip'], 'skip is clean');
  _expectClean(['skip', 'skip'], 'double skip is clean');

  if (_failures > 0) {
    stderr.writeln('$_failures check(s) failed');
    exit(1);
  }
  stdout.writeln('All changelog entry checks passed.');
}
