"""Implementation of the dart_test rule.

Unified with `dart_binary`: the test's `main` is compiled to a self-contained
kernel (`.dill`) **at build time**, so package resolution and `part`/`import`
co-location happen in the execroot — exactly where `dart_binary` already proves
they work — and the test launcher merely runs the dill. No sources, no
`package_config`, and no co-location are needed at runtime, so manifest-mode
runfiles (Windows) are a non-issue.
"""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartInfo")
load("//dart/private:build_settings.bzl", "EXTRA_DART_DEFINES_ATTR", "merge_dart_defines")
load(
    "//dart/private:common.bzl",
    "DART_ABI_CONSTRAINT_ATTRS",
    "WINDOWS_CONSTRAINT_ATTR",
    "check_unreplaced_hooks",
    "code_asset_entries",
    "collect_transitive_code_assets",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "create_test_executable",
    "gen_kernel_native_assets_action",
    "generate_native_assets_yaml",
    "generate_stable_package_config",
    "resolve_code_assets",
    "runfiles_path",
    "target_dart_abi",
)
load("//dart/private:dart_compile.bzl", "dart_compile_action")
load(
    "//dart/private:dart_kernel.bzl",
    "DartKernelInfo",
    "MODULAR_KERNEL_ATTRS",
    "MODULAR_KERNEL_TOOLCHAINS",
    "entry_source_uri",
    "entry_sources",
    "modular_executable_kernel",
    "modular_executable_tools",
)
load("//dart/private:dart_test_runner.bzl", "DartTestKernelInfo", "DartTestRunnerInfo")
load("//dart/private:executable_package.bzl", "EXECUTABLE_PACKAGE_ATTRS", "executable_package")
load("//dart/private:source_set.bzl", "COPY_TO_DIRECTORY_TOOLCHAINS", "colocate_executable")

def _dart_test_impl(ctx):
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    workspace_name = ctx.workspace_name

    # Co-locate each dep package's source+generated (and split-across-targets)
    # files into one real directory, and the test's own `main` with any generated
    # sibling sources (e.g. a `.mocks.dart`), so the build-time compile resolves
    # everything.
    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    runner = _test_runner(ctx, own.packages)
    kernel = _compile_test_kernel(ctx, own, bootstrap = runner != None)
    dill = kernel.dill

    # Thin launcher: run the self-contained dill with asserts enabled. The dill
    # carries all sources/imports, so runfiles need only the VM and (for code
    # assets) the `.so` libraries.
    env = {
        "RULES_DART_DART": runfiles_path(dart_sdk_info.dart, workspace_name),
        "RULES_DART_DILL": runfiles_path(dill, workspace_name),
    }
    runner_files = []
    if runner:
        # The runner reads the test file for its annotations (`@TestOn`,
        # `@Timeout`, `@Tags`) and names the suite after it.
        env["RULES_DART_TEST_RUNNER"] = runfiles_path(runner, workspace_name)
        env["RULES_DART_TEST_MAIN"] = runfiles_path(ctx.file.main, workspace_name)
        env["RULES_DART_TEST_PATH"] = _test_path(ctx)
        runner_files = [runner, ctx.file.main]
    executable, env_info, tool_runfiles = create_test_executable(
        ctx,
        ctx.attr._tool,
        env = env,
    )

    # A dep's `lib/**` non-Dart files are part of the package at run time under
    # pub, and the dill carries only compiled code — so they come in here, the
    # same way `dart_binary` stages them, and are reached with `rlocation`.
    #
    # The test runs its kernel with the launcher and the VM, so it takes only
    # `runtime_files`. A test that runs SDK commands itself (`dart format`,
    # `dart compile`) declares `@rules_dart//dart` in `data`, which brings the
    # whole SDK.
    runfiles = ctx.runfiles(
        files = [dill] + kernel.runtime_libs + runner_files + ctx.files.data,
        transitive_files = depset(
            transitive = [
                dart_sdk_info.runtime_files,
                collect_transitive_resources(ctx.attr.deps),
            ],
        ),
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_dep in ctx.attr.data:
        runfiles = runfiles.merge(data_dep[DefaultInfo].default_runfiles)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        env_info,
        # See `dart_binary`: analyzable and fixable without becoming a valid
        # `deps` entry. Built from the pre-colocation `ctx.file.main`, because
        # the analyze/fix rules stage by `short_path`.
        own.analyzable,
    ]

def _compile_test_kernel(ctx, own, bootstrap):
    """Compiles a test's `main` to the kernel that a test runs from.

    `dart_test` and `dart_test_kernel` both compile through here, so the kernel
    a runner snapshot is trained on is built exactly as the kernel a test runs
    is.

    Args:
      ctx: The rule context, carrying the test attributes.
      own: The `executable_package` result for the test's own sources.
      bootstrap: Whether the test runs under `package:test`'s runner, so that
        the compiled entrypoint is the bootstrap that hands `main` to it. The
        kernel is then declared where the runner's `--precompiled` layout
        expects it.

    Returns:
      `struct(dill, runtime_libs)`: the kernel `.dill` File, and the code-asset
      libraries that ship in runfiles beside it.
    """
    toolchain = ctx.toolchains["//dart:toolchain_type"]
    dart_sdk_info = toolchain.dart_sdk_info
    packages = own.packages

    hook_err = check_unreplaced_hooks(ctx.label, packages)
    if hook_err != None:
        fail(hook_err)

    # Transitively propagated assets plus any named outright — see the same
    # comment in `dart_binary`.
    resolved_assets = resolve_code_assets(
        ctx.label,
        collect_transitive_code_assets(ctx.attr.deps),
        [dep[DartCodeAssetInfo] for dep in ctx.attr.code_assets],
    )
    defines = merge_dart_defines(ctx)

    kernel_tools = modular_executable_tools(
        ctx,
        [ctx.file.main] + ctx.files.srcs,
        own.record,
        kernel_mode = True,
        resolved_assets = resolved_assets,
        # The test's own `defines` only: the `extra_dart_defines` flag is the same
        # for every module, so it does not stop a test going modular.
        own_defines = ctx.attr.defines,
        compile_flags = [],
    )
    if kernel_tools != None:
        return _compile_modular_test_kernel(ctx, own, bootstrap, kernel_tools)

    # The one flatten per rule: colocation inspects per-file paths.
    colocated = colocate_executable(
        ctx,
        packages,
        collect_transitive_srcs(ctx.attr.deps).to_list(),
        ctx.file.main,
        ctx.files.srcs,
        own.record,
    )
    packages = colocated.packages
    main_input = colocated.main_input
    main_arg = colocated.main_arg
    compile_srcs = colocated.srcs
    if bootstrap:
        # Under the runner the compiled entrypoint is a bootstrap that hands
        # `main` to `package:test`; the test file itself becomes an input.
        compile_srcs = compile_srcs + [main_input]
        main_input = _write_bootstrap(ctx, main_arg)
        main_arg = main_input.path

    # Root resolution must see the rule's own inputs too: a package whose
    # metadata comes from a srcs-less façade library resolves only via the
    # files this rule supplies itself.
    package_config = ctx.actions.declare_file(ctx.label.name + ".package_config.json")
    ctx.actions.write(
        output = package_config,
        content = generate_stable_package_config(packages, compile_srcs, colocated.roots),
    )

    dill = _test_kernel_output(ctx, bootstrap)
    runtime_libs = []

    if resolved_assets:
        # Embed the code-asset mapping in the kernel (`gen_kernel --native-assets`),
        # with `relative` paths resolved against the dill at runtime — the same
        # build-time path `dart_binary` uses. The `.so` libraries ship in runfiles.
        abi = target_dart_abi(ctx)
        entries, runtime_libs = code_asset_entries(
            ctx.label,
            resolved_assets,
            dill.dirname,
        )
        native_assets_yaml = ctx.actions.declare_file(ctx.label.name + ".native_assets.yaml")
        ctx.actions.write(
            output = native_assets_yaml,
            content = generate_native_assets_yaml(abi, entries),
        )
        gen_kernel_native_assets_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = main_input,
            transitive_srcs = depset(compile_srcs),
            package_config = package_config,
            native_assets_yaml = native_assets_yaml,
            output_dill = dill,
            main_path = main_arg,
            defines = defines,
        )
    else:
        dart_compile_action(
            ctx = ctx,
            dart_sdk_info = dart_sdk_info,
            main = main_input,
            srcs = compile_srcs,
            package_config = package_config,
            output = dill,
            compile_mode = "kernel",
            main_path = main_arg,
            defines = defines,
        )
    return struct(dill = dill, runtime_libs = runtime_libs)

def _test_kernel_output(ctx, bootstrap):
    """Declares the kernel a test runs from, in the place its runner expects.

    Args:
      ctx: The rule context.
      bootstrap: Whether the test runs under the `package:test` runner.

    Returns:
      The output File.
    """
    if bootstrap:
        # Declared where the runner's `--precompiled` layout expects it, so it
        # is loaded in place: code-asset paths are relative to the dill, and a
        # copy elsewhere would leave them pointing at nothing.
        return ctx.actions.declare_file(
            "%s.precompiled/%s.vm_test.vm.app.dill" % (ctx.label.name, _test_path(ctx)),
        )
    return ctx.actions.declare_file(ctx.label.name + ".dill")

def _compile_modular_test_kernel(ctx, own, bootstrap, tools):
    """Compiles a test's entry module and links it, in place of the monolithic kernel.

    The entry module holds only the test (or its bootstrap) and the test's own
    sources. Everything the test imports is in a dependency module, which the
    link concatenates in. The sources are addressed by where they sit, so the
    test's relative imports resolve as they do in the monolithic compile.

    Args:
      ctx: The rule context.
      own: The `executable_package` result for the test's own sources.
      bootstrap: Whether the test runs under the `package:test` runner.
      tools: The exec kernel tools, from `modular_executable_tools`.

    Returns:
      `struct(dill, runtime_libs)`, as `_compile_test_kernel` returns. Modular
      mode takes no code assets, so `runtime_libs` is empty.
    """
    dill = _test_kernel_output(ctx, bootstrap)
    if bootstrap:
        entry_files = [_write_modular_bootstrap(ctx), ctx.file.main]
    else:
        entry_files = [ctx.file.main]
    modular_executable_kernel(
        ctx,
        tools,
        entry_sources(entry_files + ctx.files.srcs),
        own.packages,
        [dep[DartKernelInfo] for dep in ctx.attr.deps],
        dill,
    )
    return struct(dill = dill, runtime_libs = [])

def _write_modular_bootstrap(ctx):
    """Writes the modular entrypoint: the runner's bootstrap, importing the test by URI.

    The monolithic bootstrap imports the test by a path relative to itself. A
    modular entry module names every source by its `org-dartlang-bazel` URI, so
    the import names the test the same way, and the test's own relative imports
    resolve from that URI.

    Args:
      ctx: The rule context.

    Returns:
      The bootstrap File.
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".vm_test.dart")
    ctx.actions.write(
        output = bootstrap,
        content = _BOOTSTRAP.format(
            test = ctx.file.main.short_path,
            import_path = entry_source_uri(ctx.file.main.short_path),
        ),
    )
    return bootstrap

def _dart_test_kernel_impl(ctx):
    own = executable_package(ctx, [ctx.file.main] + ctx.files.srcs)
    dill = _compile_test_kernel(ctx, own, bootstrap = True).dill
    test_path = _test_path(ctx)

    # The runner's `--precompiled` directory: the kernel's path less the
    # `/<testPath>.vm_test.vm.app.dill` layout that `dart_test` declares it at.
    suffix = "/" + test_path + ".vm_test.vm.app.dill"
    return [
        DefaultInfo(files = depset([dill])),
        DartTestKernelInfo(
            dill = dill,
            precompiled_dir = dill.path[:-len(suffix)],
            test_path = test_path,
            source = ctx.file.main,
        ),
    ]

def _test_runner(ctx, packages):
    """The `package:test` runner for this test, or `None` to run it directly.

    The runner is found on the direct dependency that provides `package:test`
    (see `dart_test_runner.bzl`). A test that reaches `package:test` only
    through another library is refused rather than run directly: run directly
    it would silently lose the filter, sharding and timeout behaviour Bazel
    expects, which is a worse failure than a clear one here.

    Args:
      ctx: The rule context.
      packages: The test's `DartPackageInfo` closure.

    Returns:
      The runner `.dill` File, or `None`.
    """
    for dep in ctx.attr.deps:
        if DartTestRunnerInfo in dep:
            return dep[DartTestRunnerInfo].runner
    for pkg in packages:
        if pkg.package_name == "test":
            fail(("%s: depends on `package:test` without listing it in " +
                  "`deps`. Add the `package:test` target (e.g. " +
                  "`@<hub>//:test`) to `deps`: `dart_test` runs tests through " +
                  "the runner that target carries.") % ctx.label)
    return None

def _test_path(ctx):
    """The test's path as the runner names it.

    That is its `short_path`, with a file from another repository placed under
    `external/` rather than above the root.

    Args:
      ctx: The rule context.

    Returns:
      The forward-slashed relative path.
    """
    path = ctx.file.main.short_path
    return "external/" + path[3:] if path.startswith("../") else path

_BOOTSTRAP = """\
// Generated by rules_dart: runs `{test}` under the `package:test` runner.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/bootstrap/vm.dart';

import '{import_path}' as test;

void main(List<String> _, SendPort sendPort) {{
  internalBootstrapVmTest(() {{
    final Function main = test.main;
    // The runner calls `main` with no arguments. A test that reads its
    // `args` gets the ones Bazel would have passed it, from the launcher.
    if (main is void Function(List<String>)) {{
      final encoded = Platform.environment['RULES_DART_TEST_ARGS'] ?? '[]';
      final args = (jsonDecode(encoded) as List).cast<String>();
      return () => main(args);
    }}
    return main;
  }}, sendPort);
}}
"""

def _write_bootstrap(ctx, main_path):
    """Writes the entrypoint compiled in place of the test's own `main`.

    The test file is imported by a path relative to the bootstrap, which is
    what keeps its own relative imports and `part`s resolving exactly as they
    do when it is compiled directly.

    Args:
      ctx: The rule context.
      main_path: Exec-root-relative path of the test's (possibly colocated)
        main file.

    Returns:
      The bootstrap File.
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".vm_test.dart")
    depth = len(bootstrap.dirname.split("/"))
    ctx.actions.write(
        output = bootstrap,
        content = _BOOTSTRAP.format(
            test = ctx.file.main.short_path,
            import_path = "../" * depth + main_path,
        ),
    )
    return bootstrap

# The attributes that define a test's kernel, shared by `dart_test` and
# `dart_test_kernel` so the two compile the same way.
_TEST_KERNEL_ATTRS = dict({
    "main": attr.label(
        doc = "The Dart test file to run. Must contain a top-level `main()` function.",
        mandatory = True,
        allow_single_file = [".dart"],
    ),
    "srcs": attr.label_list(
        doc = "Additional Dart source files that are part of this test's package but not reachable via `deps`.",
        allow_files = [".dart"],
    ),
    "deps": attr.label_list(
        doc = "`dart_library` targets this test depends on.",
        providers = [DartInfo],
    ),
    "defines": attr.string_list(
        doc = """Dart environment declarations (`key=value`). Each entry becomes a `-Dkey=value` \
flag on the build-time compile, so `String.fromEnvironment` resolves to it. Set these here rather \
than at run time: the test's `main` is compiled to a kernel during the build, and environment \
declarations are resolved by the front end at that point — the VM cannot supply them later.""",
    ),
    "code_assets": attr.label_list(
        doc = """Native code assets (e.g. `//dart/ext/sqlite3:code_asset`) the test's \
`@Native` FFI bindings resolve against. When set, the test's `main` is compiled to a kernel \
with the code-asset mapping embedded (`gen_kernel --native-assets`), and the libraries ship in \
runfiles so the Dart VM resolves them — no `dart:ffi` ceremony in the test source. Each entry \
must provide `DartCodeAssetInfo` (see the `dart_code_asset` rule).""",
        providers = [DartCodeAssetInfo],
    ),
}, **dict(WINDOWS_CONSTRAINT_ATTR, **dict(DART_ABI_CONSTRAINT_ATTRS, **dict(EXTRA_DART_DEFINES_ATTR, **dict(MODULAR_KERNEL_ATTRS, **EXECUTABLE_PACKAGE_ATTRS)))))

dart_test = rule(
    implementation = _dart_test_impl,
    attrs = dict(
        _TEST_KERNEL_ATTRS,
        data = attr.label_list(
            doc = "Additional files needed at runtime. These are added to runfiles so they can be resolved via `Runfiles.rlocation()`.",
            allow_files = True,
        ),
        _tool = attr.label(
            default = "//dart/private/tools:test_runner",
            executable = True,
            cfg = "exec",
        ),
    ),
    test = True,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = (
        "Compiles a Dart test to a kernel at build time and runs it with " +
        "asserts enabled. A test with `package:test` in `deps` runs under " +
        "that package's runner, so `--test_filter`, `shard_count` and " +
        "per-case results work and Bazel's `timeout` is the only time limit."
    ),
)

dart_test_kernel = rule(
    implementation = _dart_test_kernel_impl,
    attrs = _TEST_KERNEL_ATTRS,
    toolchains = ["//dart:toolchain_type"] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = (
        "Compiles a test to the kernel that `dart_test` runs under the " +
        "`package:test` runner, without a runner of its own. " +
        "`dart_test_runner_snapshot` trains the runner on one of these."
    ),
)
