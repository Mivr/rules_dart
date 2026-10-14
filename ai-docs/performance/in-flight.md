# Work in flight

Snapshot as of 2026-10-14. None of this is on `main`. It lives in git worktrees
local to the reviewing agent's session and lands on `main` one item at a time,
after verification. Until then, treat the designs here as likely, not final:
build on `main`, not on this.

## Modular kernel compilation (plan #7)

- **Shape**: `dart/private/dart_kernel.bzl` (new). `DartKernelInfo(dill,
  transitive_dills (postorder depset), modular)`.
  - Each `dart_library` declares a lazy module compile (`DartKernel`
    mnemonic, persistent worker).
  - `dart_test` compiles an entry module (bootstrap, test, own `srcs`; no
    `--exclude-non-sources`) and links with a compiled `kernel_link` tool
    (`DartKernelLink`).
  - Flag `//dart:modular_kernel`, default on.
- **Falls back to whole-program** when:
  - a dep lacks `DartKernelInfo`;
  - a package name maps to two `lib_root`s;
  - native code assets are used;
  - the test sets its own `defines`;
  - a source is duplicated;
  - the exec and target SDK versions differ;
  - the SDK has no `kernel_worker_aot` snapshot.
- **Being built now**: `dart/private/tools/kernel_module.dart`. It wraps
  `kernel_worker`, drops the sources the CFE reports errors in, and retries. It
  logs dropped files to `<module>.dropped.txt`. Global `--extra_dart_defines`
  are passed to modules.
- **Not modular**: `dart_binary` in any mode. A `_kernel_link` attr on
  `dart_binary` would make a cycle.

## Analyzer summaries, opt-in (plan #8)

- **Shape**: flag `//dart:analyzer_summaries`, default off.
  - Aspect `dart_analyzer_summary` (`dart/private/dart_analyzer_summary.bzl`)
    propagates along `deps` and `library`. It provides
    `DartAnalyzerSummaryInfo`.
  - `dart_analyze` `requires` it, and in summary mode stages only the target's
    own files.
  - Tool: `dart/private/tools/analyzer_summary.dart`, with modes `sdk`,
    `summarize` and `analyze`. It prints diagnostics in `dart analyze`'s format.
- **Done**: summaries work; non-lint diagnostics match `dart analyze` word for
  word (`unused_local_variable` at the same position, same text). Leaf body edit:
  1 summary + 1 analysis re-run instead of 61.
- **Blocked: lint rules.** `third_party/dart_linter/` (SDK `pkg/linter/lib` at
  tag 3.13.5, commit `04bcd1036cdc799ac6564988f159ee454d42c822`, unmodified,
  BSD-3) is vendored in the worktree. It does not compile against analyzer
  13.3.0: 135 errors. A separate hub on analyzer 14.1.0 is impossible, because
  rules_dart's `pub` extension allows one version of each package per module
  (`_fe_analyzer_shared has conflicting versions`). Moving the whole module to
  14.1.0 breaks `go_router_builder` resolution and changes 97 shim dependency
  versions. Options are being put to the user (see `decisions.md` once
  decided).
- **Needs**, before landing: a `MODULE.bazel.lock` refresh if a hub is added,
  and the CI analysis red paths passing with the flag on.

## Reproducible outputs (plan #9)

- `dart_compile_action` and `gen_kernel_native_assets_action` move to
  `gen_kernel` with the `org-dartlang-bazel` multi-root file system.
  - `exe`/`aot-snapshot`: an AOT kernel with stable URIs, then
    `dart compile exe <dill>`.
- `runner_snapshot.dart`: train with `--deterministic --target_unknown_cpu`, in
  a fixed-length `/tmp` scratch dir, with an explicit minimal environment. On
  Windows: no snapshot, unless a fixed-length root can be guaranteed.
- Acceptance: two clean builds produce byte-identical `.dill`/`.jit`/`.aot`/exe
  outputs, and no `linux-sandbox`, `/root/.cache` or `execroot` strings in them.
