"""Analysis-time tests for cross-compilation targets.

These resolve a cross toolchain and inspect the compile action, so they run on
any host without executing the compiler. They verify the target flags, the
pinned cross-SDK inputs (`gen_snapshot_<host>_<target>` and
`dartaotruntime_<target>`) declared on the `DartCompile` action, and the
per-action private `HOME` directory. Byte-level proof that each target really
produces its architecture lives in `e2e/cross_compile`.

Because analysis resolves the cross toolchain from whatever host runs the test,
one suite covers `linux-x64_cross_*` on Linux CI, `macos-arm64_cross_*` on
macOS, and `windows-x64_cross_*` on Windows.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

_DART_COMPILE = "DartCompile"

def _compile_action(env):
    """The target's DartCompile action, or None."""
    for action in analysistest.target_actions(env):
        if action.mnemonic == _DART_COMPILE:
            return action
    return None

def _flag_value(argv, flag):
    """The token following `flag` in argv, or None if the flag is absent."""
    for i in range(len(argv) - 1):
        if argv[i] == flag:
            return argv[i + 1]
    return None

def _prefixed_flag_value(argv, prefix):
    """The value of a `--flag=value` token in argv, or None if absent."""
    for arg in argv:
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return None

def _assert_private_home_env(env, action):
    """Asserts that `action.env` clears HOME/USERPROFILE/LOCALAPPDATA and never points to a shared directory."""
    output = action.outputs.to_list()[0]
    home_keys = [k for k in ("HOME", "USERPROFILE", "LOCALAPPDATA") if k in action.env]
    asserts.true(
        env,
        len(home_keys) > 0,
        "%s action env must set HOME or USERPROFILE/LOCALAPPDATA: %s" % (_DART_COMPILE, action.env),
    )
    for key in home_keys:
        val = action.env[key]
        asserts.equals(
            env,
            "",
            val,
            "%s must be empty in action.env (populated at runtime in system temp), got %s" % (key, val),
        )
        asserts.false(
            env,
            val == "/tmp" or val.startswith("/tmp/") or val.startswith("/var/tmp") or val.startswith("~") or val == output.dirname,
            "%s must not point to a shared directory: %s" % (key, val),
        )

def _cross_flags_test_impl(ctx):
    env = analysistest.begin(ctx)
    action = _compile_action(env)
    if action == None:
        asserts.true(env, False, "no %s action on the target" % _DART_COMPILE)
        return analysistest.end(env)

    argv = action.argv
    target_os = ctx.attr.expected_target_os
    target_arch = ctx.attr.expected_target_arch
    asserts.equals(
        env,
        target_os,
        _flag_value(argv, "--target-os"),
        "--target-os",
    )
    asserts.equals(
        env,
        target_arch,
        _flag_value(argv, "--target-arch"),
        "--target-arch",
    )
    for flag in ctx.attr.expected_flags:
        asserts.true(
            env,
            flag in argv,
            "%s missing from %s argv: %s" % (flag, _DART_COMPILE, argv),
        )

    input_files = action.inputs.to_list()
    input_paths = {f.path: True for f in input_files}
    target_suffix = "_%s_%s" % (target_os, target_arch)
    gen_snapshots = [
        f
        for f in input_files
        if f.basename.startswith("gen_snapshot_") and (
            f.basename.endswith(target_suffix) or f.basename.endswith(target_suffix + ".exe")
        )
    ]
    asserts.equals(
        env,
        1,
        len(gen_snapshots),
        "expected cross gen_snapshot*%s in %s inputs, got %s" % (
            target_suffix,
            _DART_COMPILE,
            [f.basename for f in input_files],
        ),
    )
    expected_runtime_name = "dartaotruntime_%s_%s" % (target_os, target_arch)
    runtimes = [f for f in input_files if f.basename == expected_runtime_name]
    asserts.equals(
        env,
        1,
        len(runtimes),
        "expected %s in %s inputs, got %s" % (
            expected_runtime_name,
            _DART_COMPILE,
            [f.basename for f in input_files],
        ),
    )

    gen_snapshot_arg = _prefixed_flag_value(argv, "--gen-snapshot=")
    asserts.equals(
        env,
        gen_snapshots[0].path,
        gen_snapshot_arg,
        "--gen-snapshot must reference the declared cross_gen_snapshot input",
    )
    asserts.true(env, gen_snapshot_arg in input_paths, "--gen-snapshot path must be in action.inputs")

    runtime_arg = _prefixed_flag_value(argv, "--dartaotruntime=")
    asserts.equals(
        env,
        runtimes[0].path,
        runtime_arg,
        "--dartaotruntime must reference the declared cross_dartaotruntime input",
    )
    asserts.true(env, runtime_arg in input_paths, "--dartaotruntime path must be in action.inputs")

    _assert_private_home_env(env, action)
    return analysistest.end(env)

# `analysistest.make` hands `config_settings` to a skylib-defined rule, which
# resolves plain label strings in *skylib's* repo context. `Label()` resolves
# here instead, and stringifies to a canonical label that is unambiguous
# wherever it lands.
def _platform_label(name):
    return str(Label("//dart/tests/cross_fixture:" + name))

def _make_cross_flags_test(platform_name):
    return analysistest.make(
        _cross_flags_test_impl,
        attrs = {
            "expected_target_os": attr.string(),
            "expected_target_arch": attr.string(),
            "expected_flags": attr.string_list(),
        },
        config_settings = {
            "//command_line_option:platforms": [_platform_label(platform_name)],
        },
    )

riscv64_flags_test = _make_cross_flags_test("linux_riscv64")

armv7_flags_test = _make_cross_flags_test("linux_arm")

def _native_has_no_target_flags_test_impl(ctx):
    """A native build must get neither target flags nor cross-SDK inputs.

    `dart_compile.bzl` gates them on a non-empty `target_os`, which is empty for
    native toolchains. Passing `--target-os` for the host would be accepted and
    silently change nothing, so nothing else would catch a regression here.
    """
    env = analysistest.begin(ctx)
    action = _compile_action(env)
    if action == None:
        asserts.true(env, False, "no %s action on the target" % _DART_COMPILE)
        return analysistest.end(env)
    argv = action.argv
    asserts.false(env, "--target-os" in argv, "native build passed --target-os")
    asserts.false(env, "--target-arch" in argv, "native build passed --target-arch")
    asserts.equals(env, None, _prefixed_flag_value(argv, "--gen-snapshot="), "native build passed --gen-snapshot")
    asserts.equals(env, None, _prefixed_flag_value(argv, "--dartaotruntime="), "native build passed --dartaotruntime")
    cross_inputs = [
        f.basename
        for f in action.inputs.to_list()
        if f.basename.startswith("gen_snapshot_") or f.basename.startswith("dartaotruntime_linux_")
    ]
    asserts.equals(env, [], cross_inputs, "native build declared cross-SDK inputs: %s" % cross_inputs)
    _assert_private_home_env(env, action)
    return analysistest.end(env)

native_has_no_target_flags_test = analysistest.make(
    _native_has_no_target_flags_test_impl,
)

def _abi_manifest_test_impl(ctx):
    """The code-asset ABI string written for a cross target.

    Pins the whole chain — constraint probe in `target_dart_abi` through to the
    emitted `native_assets.yaml` key. The fixture deliberately uses a
    `dynamic_loading_system` asset: a `cc_shared_library`-backed one would make
    Bazel resolve a cc toolchain for riscv64/armv7 during analysis and fail
    before `target_dart_abi` ever ran, testing the wrong thing.
    """
    env = analysistest.begin(ctx)
    manifests = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FileWrite" and
           a.outputs.to_list()[0].basename.endswith(".native_assets.yaml")
    ]
    asserts.equals(env, 1, len(manifests), "expected one native_assets.yaml write")
    content = manifests[0].content
    asserts.true(
        env,
        ('"native-assets": {"%s"' % ctx.attr.expected_abi) in content,
        "ABI %s missing from manifest: %s" % (ctx.attr.expected_abi, content),
    )
    return analysistest.end(env)

def _make_abi_manifest_test(platform_name):
    return analysistest.make(
        _abi_manifest_test_impl,
        attrs = {"expected_abi": attr.string()},
        config_settings = {
            "//command_line_option:platforms": [_platform_label(platform_name)],
        },
    )

riscv64_abi_test = _make_abi_manifest_test("linux_riscv64")

armv7_abi_test = _make_abi_manifest_test("linux_arm")

def _cross_jit_refusal_test_impl(ctx):
    """Asserts that cross-compiling jit-snapshot fails analysis naming target and reason."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.expect_failure(env, str(target.label))
    asserts.expect_failure(
        env,
        "jit-snapshot is host-only because it trains on the build machine's Dart VM and has no target OS/CPU flags; use `exe` or `aot-snapshot` to cross-compile",
    )
    return analysistest.end(env)

def _make_cross_jit_refusal_test(platform_name):
    """Creates an expect_failure analysis test for jit-snapshot on `platform_name`."""
    return analysistest.make(
        _cross_jit_refusal_test_impl,
        expect_failure = True,
        config_settings = {
            "//command_line_option:platforms": [_platform_label(platform_name)],
        },
    )

riscv64_jit_refusal_test = _make_cross_jit_refusal_test("linux_riscv64")
armv7_jit_refusal_test = _make_cross_jit_refusal_test("linux_arm")
arm64_jit_refusal_test = _make_cross_jit_refusal_test("linux_arm64")
x64_jit_refusal_test = _make_cross_jit_refusal_test("linux_x64")

def _native_jit_success_test_impl(ctx):
    """Asserts that native jit-snapshot analysis produces actions without failure."""
    env = analysistest.begin(ctx)
    actions = [a.mnemonic for a in analysistest.target_actions(env)]
    asserts.true(env, len(actions) > 0, "expected actions for native jit-snapshot")
    return analysistest.end(env)

x64_native_jit_success_test = analysistest.make(
    _native_jit_success_test_impl,
    config_settings = {
        "//command_line_option:platforms": [_platform_label("linux_x64")],
    },
)
