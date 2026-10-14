# Work in flight

Snapshot as of 2026-10-14. None of this is on `main`. It lives in git worktrees
local to the reviewing agent's session and lands on `main` one item at a time,
after verification. Until then, treat the designs here as likely, not final:
build on `main`, not on this.

## Modular kernel compilation

Landed on `main` as `959b7b3`; see `plan.md`, `findings.md` and `for-rules-flutter.md`.

## Analyzer summaries

Landed on `main` as `398116c`; see `plan.md`.

## Reproducible outputs

Landed on `main` as `d2120e8`; see `plan.md` and `for-rules-flutter.md`.

## Analyzer-only SDK file set

Landed on `main` as `8a1e20d`; see `plan.md` and `for-rules-flutter.md`.

## Codegen on analyzer summaries (plan #12)

Landed on `main` as `4090db6` (summary-mode fixes) and `dfb6274` (codegen).
Summaries and generated files are byte-identical across install paths.

## Multi-root whole-program compile (plan #13)

Landed on `main` as `09c5905`; see `plan.md` and `for-rules-flutter.md`.

## Regression: libraries that do not compile on their own (plan #14)

Found on `main` after `959b7b3`, with `//dart:modular_kernel` on (the default).
`e2e/ext_exemplar` `//json_serializable:_advanced_sources` is a sources-only
`dart_library` whose file imports a package it does not declare and whose
`part` lives on another target (`:advanced`, which lists the same files).
Whole-program compiles never built a library alone, so it worked; the modular
compile builds each library's module and fails ("Couldn't resolve the package
'json_annotation'"). Whole-program mode still builds it.

Also found: `duplicated_source` cannot see a file listed by two libraries,
because the closure is a depset and the identical File is deduplicated.

Fix being built: the module planner treats a source as not compilable in the
module when it imports a package missing from the module's package config, or
names a `part` that is not among the module's inputs (plus its importers), the
way it already treats web-only files. The executable's entry module compiles
such files from source. A dependent that lists the same file compiles it itself.

Why it got through: the reviewing harness's e2e suite skipped `ext_exemplar`,
whose Gazelle targets need go.dev (blocked in this sandbox). It now builds a
copy with the Gazelle targets stripped (see `harness/README.md`).

## Regression: a dependency's `main` starts the test (plan #14)

Also from `959b7b3`: `//dart/ext/tools:check_dual_build_collisions_test` times
out with modular on. Its library dependency defines a top-level `main`, and the
linked kernel starts there instead of at the test's entry. Passes with
`--@rules_dart//dart:modular_kernel=false` and before `959b7b3`. Missed because
verification ran `//dart/tests/...`, `//dart/private/tools/...` and
`//dart/runfiles/...` but not `//dart/ext/...`; it now runs `//dart/ext/...`
with `--keep_going` (the sqlite targets cannot fetch in this sandbox).

## Drop `bazel_lib` (plan #11)

The only use is `assemble_source_dir` (`copy_to_directory`). Being replaced by
a `dart:io`-only copy tool behind a new `//dart:copy_toolchain_type`, so the
public `COPY_TO_DIRECTORY_TOOLCHAINS` / `colocate_*` helpers keep working for
downstream rule sets unchanged. Acceptance: copied trees byte-identical to
`copy_to_directory`'s (shown on e2e/codegen, analysis staging, a tree-artifact
fixture and an external-repo probe). Cost: about +30 ms per copy action (Dart
exe startup vs Go). `bazel_lib` stays in users' graphs through `yaml.bzl`
(plan #15), so the two land together with one lock refresh.
