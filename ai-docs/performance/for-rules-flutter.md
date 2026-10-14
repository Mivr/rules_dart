# What this means for rule sets built on rules_dart

Written for the agent maintaining rules_flutter (and rules_dart_proto). It
lists everything that changed, or will change, in rules_dart's public or
semi-public surface, and what a downstream rule set should check.

## Landed on `main`

### `DartSdkInfo` has two new fields (`b3c8dc3`)

- `compile_files`: the SDK files `dart compile`, `gen_kernel` and `dart format`
  open.
- `runtime_files`: what running a compiled kernel needs, used for `dart_test`
  runfiles.

`dart_toolchain` takes optional `compile_files` / `runtime_files` labels. When
unset, both fall back to `tool_files`, so a toolchain declared by another rule
set keeps its old behaviour. To get the speedup with the Flutter SDK's bundled
Dart, declare the two filegroups, mirroring the generated ones in
`dart/repositories.bzl`. Note that the Flutter SDK lays out its Dart SDK under
`bin/cache/dart-sdk`.

### `dart_test` runfiles no longer carry the whole SDK (`b3c8dc3`)

A test that runs SDK commands itself declares `@rules_dart//dart` in `data`.
Check `flutter_test` or any rule that reuses `dart_test`'s runfiles helpers.

### `DartTestRunnerInfo.runner` may be an app-JIT snapshot, not a `.dill` (`de52390`)

The launcher runs it the same way (`dart --enable-asserts <runner> ...`).
`dart_test_package` gained an optional `snapshot` attr.

- New providers: `DartTestRunnerSnapshotInfo` and `DartTestKernelInfo`.
- New rule: `dart_test_kernel`, which shares `dart_test`'s compile.
- Flag: `//dart:test_runner_snapshot`.

Anything that assumes the runner is a `.dill` must accept `.jit`.

### `stage_dart_project` / `stage_config_project` gained `copy_external` (`95089ce`)

Default `True`, which is the old behaviour. With `False`, external packages
whose files sit under one exec root are named in place in
`package_config.json` (relative `rootUri` into `external/<repo>`), and their
files become inputs. Packages split across roots are still copied. Only use
`False` where the staged project is read from the exec root by an action, not
from runfiles.

### `package_for` is now `package_index` + `package_for_index` (`0e3c404`)

`package_for(short_path, packages)` still works: it builds the index per call.
Callers in loops should build the index once.

### `//dart:analyzer_summaries`, opt-in (`398116c`)

A `dart_analyzer_summary` aspect along `deps`/`library`. A rule set's library
targets get summaries when they provide `DartInfo` and list their `.dart` files
in `DefaultInfo`.

### Lockfiles

Any change to a `.bzl` file loaded by rules_dart's `pub` extension
(`dart/pub/extensions.bzl` and everything it loads, e.g.
`dart/pub/private/build_content.bzl`) changes that extension's recorded digest.
A downstream root module that commits its `MODULE.bazel.lock` and builds with
`--lockfile_mode=error` must refresh its lock when it bumps rules_dart. That's
normal for any rule-set bump, but it bit this repository once.

### Compiles go through `gen_kernel` with stable URIs (`d2120e8`)

- `dart_compile_action(ctx, dart_sdk_info, ...)` replaces the old
  `(dart_bin, sdk_files)` parameters. A rule set calling it must pass the
  toolchain's `DartSdkInfo`.
- Kernels and AOT snapshots name sources `org-dartlang-bazel:///<path>`, and
  pub/package libraries `package:`, no longer absolute `file:` URIs. This
  affects stack traces, and any tooling mapping kernel URIs to files
  (debuggers, coverage, hot reload's `generate_dev_package_config`, which uses
  `org-dartlang-app`). Check the two coexist.
- `common.bzl` helpers: `STABLE_SCHEME`, `stable_path`, `stable_entry_path`,
  `generate_stable_package_config` and `gen_kernel_args`.
- `dart_compile_flags` are split by stage (`split_compile_flags`):
  `--enable-experiment`, `-D`/`--define` and `--enable-asserts` go to the front
  end. In `jit-snapshot` mode no other flag is accepted.
- App-JIT snapshots are trained by `dart/private/tools/app_jit_snapshot.dart`
  from a copy of `dart` and `dartvm` at `/tmp/rules_dart_vm-<sdk version>/bin`.
  The training binary's absolute path changes the snapshot bytes.

### Modular `dart_test` compiles (`959b7b3`)

- Every `dart_library` provides **`DartKernelInfo`** (`kmod` tree artifact,
  `transitive_kmods`, `modular`, `closure_excluded`; see
  `dart/private/dart_kernel.bzl`). A rule set with its own
  `DartInfo`-providing library rule (e.g. a Flutter library rule) that doesn't
  provide `DartKernelInfo` makes every `dart_test` reaching it fall back to
  whole-program compilation. That's correct, just slower. Provide it, built
  with `library_kernel_info`, to opt in.
- `dart_library` now has an optional exec tools toolchain and the private
  attrs `_kernel_module` / `_modular_kernel`.
- `//dart:modular_kernel` (default on) switches it off.
- Workers: `DartKernel` actions run in a persistent worker by default (peak
  ~400 MB RSS each).

### `DartSdkInfo.analyze_files` (analysis, fix and codegen)

The SDK files `dart analyze`, `dart fix` and the analyzer-summary tool open:
the launcher, the analysis snapshots, the `lib/` sources and the
`lib/_internal` metadata. The analyze and fix actions, the summary actions, and
`dart_codegen`, `dart_aggregate_codegen` and `dart_sqlcodegen` take it instead
of the whole SDK. `dart_toolchain` takes an optional `analyze_files` label.
When it is unset the field is `tool_files`, so a toolchain declared by another
rule set keeps its old behaviour and gets the speedup only once it declares the
filegroup, mirroring the generated one in `dart/repositories.bzl`. A generator
given as a `.dart` script also takes `runtime_files`, because the `dart`
launcher runs it through `dartvm` and the kernel service.

### Whole-program compiles copy nothing (`09c5905`)

`dart_binary` and `dart_test` no longer assemble split packages into
`.pkgsrcs` tree artifacts; the multi-root compile resolves them in place.
`colocate_executable` (private) is replaced by `executable_inputs`. The public
`colocate_packages` / `colocate_entrypoint` and `COPY_TO_DIRECTORY_TOOLCHAINS`
in `dart/utils.bzl` are unchanged; no rule in rules_dart calls them any more.
`dart_binary`, `dart_test` and `dart_test_kernel` no longer declare the copy
toolchain.

### Summary-mode and codegen changes (`4090db6`, `dfb6274`)

`DartAnalyzerSummaryInfo` gained `packaged_summaries` (`depset[(package, File)]`).
Under `//dart:analyzer_summaries`, `dart_codegen` passes `--summary <path>`
(repeatable) and `--sdk-summary <path>` to every `generator_bin`; a generator
that does not use `dart/ext/lib/builder_shim.dart` must accept (or ignore)
them. With the flag off nothing changes.

### Known regressions on `main` (being fixed)

With `//dart:modular_kernel` on: a `dart_library` that does not compile on its
own (an undeclared package import, or a `part` supplied by another target)
fails the build when an executable reaches it; and a `dart_test` whose library
dependency defines a top-level `main` can start at that `main`. Workaround until the fix lands:
`--@rules_dart//dart:modular_kernel=false`. See `in-flight.md`.

## Coming (not on `main` yet; see `in-flight.md`)
