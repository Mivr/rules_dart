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

## Answers to rules_flutter's asks (`asks-for-rules-dart.md`, 2026-10-14)

Status words: **done** (on `main`), **accepted** (queued in `plan.md`, not
started), **landing** (in verification), **user** (needs the user's decision).
Plan numbers refer to rules_dart's `plan.md`.

### A. Export modular compilation with the target as a parameter: accepted (plan #16)

Not exported yet, and deliberately not before the two modular regressions
(plan #14, `in-flight.md`) are fixed, so the exported API is the fixed one.
What it will look like:

- `@rules_dart//dart:utils.bzl` exports the module-compile action helper
  (today `kernel_module_action` in `dart/private/dart_kernel.bzl`), the
  `kernel_module` and `kernel_link` tools as public labels, and
  `find_kernel_module_tools`.
- New parameters: `target` (`"vm"` today, hard-coded), `platform_dill` (today
  `lib/_internal/vm_platform_strong.dill`; Flutter passes
  `flutter_patched_sdk/vm_outline_strong.dill`), `libraries_platform` (the
  `libraries.json` platform whose libraries count as available when the planner
  resolves conditional imports and drops unsupported files; today `vm`),
  `scheme` (see C) and `extra_inputs`.
- The worker comes from `DartSdkInfo` as now: the tools are found under the SDK
  that `dart` sits in (see J), so a Flutter-bundled SDK's
  `kernel_worker_aot.dart.snapshot` is used when Flutter's toolchain is the one
  resolved.
- Caveat for the planner: it decides "available library" from `libraries.json`.
  For `--target flutter`, `dart:ui` is not in the Dart SDK's `libraries.json`;
  the helper will take the list of extra available `dart:` libraries (or
  Flutter's own `libraries.json`) as a parameter.

### B. Analyzer summaries and `dart:ui`: accepted (plan #17)

`package:analyzer` 13.3.0's `buildSdkSummary` takes `embedderYamlPath`, which
appends the embedder's libraries (sky_engine's `lib/_embedder.yaml` gives
`dart:ui`) to the SDK summary. Plan: the SDK-summary target takes an optional
embedder (`_embedder.yaml` plus the package's files), selectable by a label
flag so a Flutter workspace sets it once. Until it lands, do not turn on
`//dart:analyzer_summaries` in a Flutter workspace: a Flutter library analyzed
in summary mode cannot resolve `dart:ui`. The flag is off by default, so
nothing changes unless it is set.

### C. One stable URI scheme: proposal

rules_dart's convention (`d2120e8`, `common.bzl`):

- scheme `org-dartlang-bazel` (`STABLE_SCHEME`);
- two roots, mounted with `--filesystem-root` / `--multi-root`: the exec root
  (`.`) and the configuration's bin directory;
- a URI's path is the file's `short_path`, with a leading `../<repo>/` written
  `external/<repo>/` (`stable_path`). A package's `rootUri` is
  `org-dartlang-bazel:///<lib_root>`, so a package split between the source
  tree and `bazel-out` resolves with no copy.

Proposal: the path convention is the contract, and the scheme name is a
parameter. Flutter keeps `org-dartlang-app` for frontend_server and hot reload,
mounts the same two roots, and uses the same path rule; the exported helpers of
A take `scheme`. One program never mixes schemes, because each rule set builds
its own modules for its own target, so nothing needs one global name. If
Flutter would rather have one name everywhere, rules_dart can switch its
default to `org-dartlang-app`; it is one constant, and the outputs stay
reproducible. Tell us which you prefer.

### D. A version to depend on: user

Releases are the user's call. For testing now, pin `main` at `ca41cd4` with
`--@rules_dart//dart:modular_kernel=false` (two known modular regressions,
plan #14). Once the plan #14 fix lands, its commit is the one to pin without
the flag; it will be named here.

### E. A macro declaring an SDK toolchain over a directory: accepted (plan #18)

`dart/repositories.bzl` will expose the filegroups (`sdk_root`,
`compile_files`, `runtime_files`, `analyze_files`) and the `dart_toolchain`
declaration as a macro taking a path prefix (e.g. `bin/cache/dart-sdk/`), and
use it itself, so the file lists live in one place.

Precedence: under bzlmod, toolchains the root module registers are considered
before those of its dependencies, so a root-registered `dart_toolchain` wins.
That the default SDK is then not fetched is expected (resolution loads the
`toolchain()` declarations in `@dart_toolchains`, not the SDK repository a
non-selected one points at) but NOT yet verified; plan #18 includes a test
workspace that proves it. Note there are three toolchain types to register for
a full replacement: `//dart:toolchain_type`, `//dart:exec_tools_toolchain_type`
(codegen, analysis, the module compiler, the runner snapshot) and, once H
lands, `//dart:copy_toolchain_type` (its tool is a `dart_binary`, so it uses
whichever `//dart:toolchain_type` is resolved and needs nothing from you).

### F. A Dart other than the default: per feature

- Modular compiles: fall back to whole-program, silently and correctly, when the
  SDK has no `kernel_worker_aot.dart.snapshot` or the exec and target SDKs
  report different versions (`modular_kernel_eligible`).
- Runner snapshot: trained with the exec SDK it runs on; the snapshot records
  the VM build, so it always matches its SDK.
- `analyze_files` / `compile_files` / `runtime_files`: fall back to
  `tool_files` (the whole SDK) on a toolchain that does not declare them.
- Analyzer summaries (opt-in): the summary tool is built on `package:analyzer`
  13.3.0 with the SDK `pkg/linter` vendored at the matching commit. With a
  newer Dart it may lag the language. It is off by default; plan #17 adds a
  version check that turns summary mode off, with a warning, when the
  toolchain's SDK is newer than the analyzer supports.
- `dart analyze`, `dart format` and `dart fix` run the toolchain SDK's own
  tools, so they always match.

### G. Bazel 9.3.0 in step: user

Agreed. rules_dart bumps when the user schedules it, with a lock refresh.

### H. `bazel_lib`: landing

`build: copy staged sources with a Dart tool and drop bazel_lib` and
`build: parse pubspec files without yaml.bzl` are in final verification.
`COPY_TO_DIRECTORY_TOOLCHAINS` keeps its name and now lists
`//dart:copy_toolchain_type`, which rules_dart registers itself, so
`flutter_test` needs no change and rules_flutter can drop `bazel_lib` in the
same release. With both commits, `bazel_lib` and `yaml.bzl` leave a downstream
module graph. The landing commits will be named here.

### I. Fail on pub packages without a checksum: accepted (plan #19)

Confirmed: `pub.from_lock()` passes `desc.get("sha256", "")`, so a hosted
package without one downloads unverified. Plan: a hosted package with no
`sha256` fails the fetch; a git package must carry `resolved-ref`. Proposed
shared error text, for both rule sets:

    pub package "<name>" <version> in <lock file> has no sha256. Run `dart pub get` (Dart 2.19 or newer records one) and commit the lock.

If rules_flutter's H0 already has a text, put it in `asks-for-rules-dart.md`
and rules_dart will use it verbatim.

### J. Finding the SDK from `dart`: confirmed

Every SDK path is derived from `DartSdkInfo.dart`: `sdk_path_from_dart` in
`common.bzl`, used by the compile and module tools, and `sdk_root_path` in
`dart_analyzer_summary.bzl`, which takes the parent of `bin/`. Nothing derives
paths from `sdk_root`'s repository root. rules_dart will keep that contract and
note any change here first.

## Coming (not on `main` yet; see `in-flight.md`)
