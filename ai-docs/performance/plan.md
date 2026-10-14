# Plan and status

Benchmark: `harness/gen_bench.py`. 30 packages of 21 files each, where `pkgN`
depends on `pkg(N-1)` and `pkg(N-2)`, one `package:test` test per package, and
one `exe` binary. An 80-package variant measures analysis. Machine: 4-core
sandbox. Wall times vary by about ±6 s between identical runs, so action counts
and CPU totals are the steadier signal. Raw numbers are in `results/`.

## On `main`

| # | Commit    | Change                                                                                           | Measured effect                                                       |
| - | --------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| 1 | `0e3c404` | `package_for` indexed by `lib_root`: a lookup costs path depth, not files × packages             | Re-analysis, 80 packages: 5.97 s → 0.86 s                             |
| 2 | `6d99c78` | The format check stages only the target's own files and options, not its dependencies            | Format checks re-run after a leaf body edit: 61 → 1                   |
| 3 | `b3c8dc3` | `DartSdkInfo.compile_files` / `runtime_files`: compile, format and test runfiles get SDK subsets | Test runfiles: 1,073 files / 699 MB → 39 / 278 MB; clean build ~−5 s |
| 4 | `de52390` | `package:test` runner started from an app-JIT snapshot (`//dart:test_runner_snapshot`)           | Per test: 0.55 s → 0.25 s                                             |
| 5 | `95089ce` | Staged projects reference pub packages in place instead of copying them per target               | Clean lint: 1,692 → 282 sandboxed actions, 1,532 → 122 copies         |
| 6 | `4445fa1` | `MODULE.bazel.lock` refresh: fixes the regression #4 introduced (see `decisions.md`)            | `--lockfile_mode=error` builds pass again                             |
| 8 | `d2120e8` | Reproducible outputs: `gen_kernel` with `org-dartlang-bazel:///` URIs; deterministic, fixed-path snapshot training; `dart_compile_flags` routed by stage | Every compiled output byte-identical across clean builds and install paths; build time unchanged; per test 0.55 → 0.28 s |
| 9 | `959b7b3` | Modular `dart_test` compiles: per-SCC kernels per `dart_library`, warm `kernel_worker`, reachability-pruned link (`//dart:modular_kernel`) | Clean 22.1 → 19.9 s; leaf body edit 16.5 → 9.3 s; API edit 21.0 → 11.3 s; test kernel 13.0 → 4.2 MB |
| 7 | `398116c` | Opt-in `//dart:analyzer_summaries`: analysis against per-library summaries; SDK linter vendored  | Leaf body edit: 61 analyses → 1 (44 s → 17 s); flag off unchanged     |
| 10 | `8a1e20d` | `DartSdkInfo.analyze_files`: analyze, fix, summary and codegen actions get the analyze subset of the SDK | `DartAnalyze` inputs on `//:bad_lib`: 1,082 → 515 (SDK 1,049 → 482) |
| 13 | `09c5905` | Whole-program `dart_binary` / `dart_test` compile split packages in place (multi-root) instead of copying them into `.pkgsrcs` trees | `e2e/codegen`, modular off: copy actions 8 → 1 (the `dart_source_set`) |
| 12 | `4090db6`, `dfb6274` | Summary mode: a `srcs_dir` library no longer claims a package it has no summary for, generated libraries are summarized (own sources staged under their own root); `dart_codegen` resolves other packages from summaries under the flag | Codegen request (warm): mockito 0.64 → 0.35 s, built_value 0.35 → 0.27 s; output byte-identical |

Overall, against the original `main` (`3b0470c`):

| Metric                                | Baseline         | Now           |
| ------------------------------------- | ---------------- | ------------- |
| Re-analysis, 80 packages              | 5.97 s           | 0.89 s        |
| Per test (`package:test`)             | 0.65 s           | 0.25 s        |
| Test runfiles                         | 1,073 / 699 MB   | 39 / ~290 MB  |
| Format checks after a leaf body edit  | 61               | 1             |
| Clean lint: sandboxed actions         | 1,628–1,692      | 282           |
| Leaf body edit: compiles re-run       | 31               | 31 (see #7)   |
| Leaf body edit: analyses re-run       | 61               | 61 (see #8)   |

A consolidated before/after run on final `main` is still to do: these numbers
come from separate A/B runs.

## In flight (see `in-flight.md`)

| #  | Item                                                                                       | State                                                                                                                                                                                                  |
| -- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 14 | **Regression fixes** for modular compiles: a `dart_library` that does not compile on its own (`e2e/ext_exemplar`); a dependency library's `main` starting the linked test | Agent fixing; see `in-flight.md` |
| 15 | Drop `yaml.bzl` (its `bazel_lib` dep is what keeps `bazel_lib` in users' graphs): in-repo Starlark pubspec parser | Agent implementing, stacked on #11 |
| 11 | Drop `bazel_lib`: a Dart copy tool behind `//dart:copy_toolchain_type` | Agent implementing |

## Queued (agreed with the user, 2026-10-14)

| #  | Item                                                                                                                                                       | Depends on |
| -- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 16 | Export modular compilation for rules_flutter: helper with `target`, platform dill, available-libraries list, `scheme`, extra inputs; `kernel_module` / `kernel_link` public (ask A) | #14 |
| 17 | SDK summary takes an embedder (`_embedder.yaml`, for `dart:ui`); summary mode turns itself off on an SDK newer than its analyzer (asks B, F) | — |
| 18 | Macro declaring the SDK filegroups and `dart_toolchain` over a path prefix; test that a root-registered toolchain wins without fetching the default SDK (ask E) | — |
| 19 | `pub.from_lock()` fails on a hosted package without `sha256` (and a git package without `resolved-ref`), shared error text with rules_flutter (ask I) | — |

## Dropped

- Moving the Gazelle plugin (and with it `rules_go`) out of the core module.
  The user decided to leave it: it is breaking for Gazelle users, and its cost is
  one go.dev request when the `go_sdk` extension runs.
- Dropping the 54 MB kernel-service snapshot from test runfiles. It would break
  tests that spawn isolates from `.dart` source.
