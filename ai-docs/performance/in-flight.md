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
- **Being built now**: `dart/private/tools/kernel_module.dart`, a persistent
  worker wrapping `kernel_worker`. It speaks the worker protocol directly:
  `package:bazel_worker` would be a cycle, since every `dart_library` carries the
  tool. It plans each module's VM-compatible files from the import graph (see
  `decisions.md`), writes `<module>.vm_excluded.txt` and compiles with
  `--exclude-non-sources`. Global `--extra_dart_defines` are passed to modules.
- **Lessons from the first version**: `kernel_worker`'s incremental compiler
  writes non-protocol text to stdout on an undeclared read, which deadlocks the
  worker. So `--use-incremental-compiler` and `--reuse-compiler-result` are not
  used.
- **Not modular**: `dart_binary` in any mode. A `_kernel_link` attr on
  `dart_binary` would make a cycle.

## Analyzer summaries

Landed on `main` as `398116c`; see `plan.md`.

## Reproducible outputs

Landed on `main` as `d2120e8`; see `plan.md` and `for-rules-flutter.md`.
