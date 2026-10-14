# Vendored: the Dart lint rules

`lib/` is the lint-rule package `linter`, copied unmodified from the Dart SDK:

- Repository: `dart-lang/sdk`
- Commit: `dbeb7e1e5b7c6e23ff7a253f12607edad5129512` ("Prepare to publish analyzer 13.3.0, ...", 2026-06-11)
- Path: `pkg/linter/lib`
- Licence: BSD-3-Clause, in `LICENSE` (copied from `pkg/linter/LICENSE`)

This is the commit that published `package:analyzer` 13.3.0. Its `pkg/linter`
compiles against that exact analyzer tree, which is why it is used here rather
than the SDK 3.13.5 tag.

Difference from `dart analyze` in SDK 3.13.5: this copy registers 266 rules.
3.13.5 registers 267. The one missing rule is `migrate_design_widgets`
(`MigrateDesignWidgets`, a Flutter migration lint). Nothing else differs in the
registry.

## Why it is vendored

The SDK ships its lint rules inside `dart analyze`, and the rules are not
published: the SDK's `pkg/linter` says "DO NOT publish". The `linter` package on
pub.dev is discontinued at 1.30.1, which targets analyzer 5. `package:analyzer`
itself contains no lint rules. The `dart_analyze` aspect's analyzer-summary mode
runs `package:analyzer` through `//dart/private/tools:analyzer_summary`, so it
needs this copy to report the same lints `dart analyze` does for the SDK.

## Keeping it in step

Rule: the vendored linter must come from the SDK commit that published the
module's pinned `package:analyzer` version. Find it as the "Prepare to publish
analyzer X.Y.Z" commit in `dart-lang/sdk`. Re-vendor whenever that pin moves:
copy `pkg/linter/lib` and `pkg/linter/LICENSE` from that commit, update the
commit, path and notes above, and re-run the summary-mode checks, since a rule
can depend on an analyzer API that changed.

The analyzer pin is the resolved `analyzer` version in `dart/ext/pubspec.lock`
(currently 13.3.0; the constraint is in `dart/ext/pubspec.yaml`).

Do not edit the files here. The repository's text hooks and typo check skip this
directory (`.pre-commit-config.yaml`, `.typos.toml`).
