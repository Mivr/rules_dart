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

- `dart_codegen` resolves against the dependencies' analyzer summaries when
  `//dart:analyzer_summaries` is on, instead of analyzing the closure from
  source. The 96 generated files of `e2e/codegen` are byte-identical either
  way, and each request is 15–45% faster.
- Bug found in the landed summary mode: a library given as `srcs_dir` lists the
  directory, not `.dart` files, in `DefaultInfo`. It produces no summary yet
  still claims its package, so a dependent neither reads the package from
  source nor finds a summary for it. The fix (a target claims its package only
  when it built a summary or has no `lib/` sources) lands first, as its own
  `fix(analyze)` commit with a regression test.
- Still to prove: the generator worker's memory stays flat over 300 requests,
  or it is recycled.

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

## Drop `bazel_lib` (plan #11)

The only use is `assemble_source_dir` (`copy_to_directory`). Being replaced by
a `dart:io`-only copy tool behind a new `//dart:copy_toolchain_type`, so the
public `COPY_TO_DIRECTORY_TOOLCHAINS` / `colocate_*` helpers keep working for
downstream rule sets unchanged. Acceptance: copied trees byte-identical to
`copy_to_directory`'s.
