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
| 7  | Modular kernel compilation: one module per `dart_library`, tests link by concatenation     | Designed and verified by hand. Implementation hit web-only pub files; the fix (a wrapper that drops files failing for the VM and retries) is being built. Body edit: 31 full compiles → one module plus dependents' entry modules and links. |
| 8  | Analyzer summaries, opt-in (`//dart:analyzer_summaries`)                                    | Works; leaf body edit runs 1 analysis instead of 61 (44 s → 17 s). Lint rules are being added: SDK `pkg/linter` vendored, analyzer 14.1.0 hub.                                                         |
| 9  | Reproducible outputs: stable `org-dartlang-bazel:///` URIs via `gen_kernel`; deterministic snapshot training | Started. All 34 compiled outputs currently differ between clean builds.                                                                                                                 |

## Queued (agreed with the user, 2026-10-14)

| #  | Item                                                                                                                                                       | Depends on |
| -- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 10 | Analyzer-only SDK file set for analyze/fix/codegen actions (they still take the whole SDK; ~400 MB of it is dart2js/ddc/wasm snapshots they never open) | #8         |
| 11 | Drop the `bazel_lib` dependency: a small Dart copy tool replaces `copy_to_directory`, so users stop fetching its toolchains (`bats`, ...)                   | #7, #8     |
| 12 | `dart_codegen` resolves against analyzer summaries instead of a fresh analyzer over the whole closure                                                      | #8         |
| 13 | Whole-program fallback compile uses multi-root URIs, so split packages need no copy                                                                        | #7, #9     |

## Dropped

- Moving the Gazelle plugin (and with it `rules_go`) out of the core module.
  The user decided to leave it: it is breaking for Gazelle users, and its cost is
  one go.dev request when the `go_sdk` extension runs.
- Dropping the 54 MB kernel-service snapshot from test runfiles. It would break
  tests that spawn isolates from `.dart` source.
