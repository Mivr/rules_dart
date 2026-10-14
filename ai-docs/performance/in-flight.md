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

The fallback compile (`//dart:modular_kernel=false`, or a library without
`DartKernelInfo`) names split packages with `org-dartlang-bazel` multi-roots
instead of copying them into one directory. The remaining `copy_to_directory`
call sites it finds feed plan #11 (dropping `bazel_lib`).

