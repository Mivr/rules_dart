"""Shared compilation action helpers for Dart."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load(
    "//dart/private:common.bzl",
    "JIT_SNAPSHOT_LOCK_TIMEOUT_DEFAULT",
    "STABLE_SCHEME",
    "find_sdk_kernel_tools",
    "gen_kernel_args",
    "has_comma_define",
    "jit_train_key",
    "sdk_dartvm",
    "stable_entry_path",
    "writable_home_env",
)

# The `dart compile` modes that tree-shake, and so can record the uses of
# `@RecordUse` definitions: what survives tree-shaking is the set of uses.
RECORDING_COMPILE_MODES = ("exe", "aot-snapshot")

def recorded_uses_kind(compile_mode):
    """The `DartRecordedUsesInfo.kind` a `dart_binary` in `compile_mode` provides.

    Args:
        compile_mode: The `dart compile` mode.

    Returns:
        `aot` when the compiler records the uses, `empty` when it cannot.
    """
    return "aot" if compile_mode in RECORDING_COMPILE_MODES else "empty"

def defines_stage_error(defines, package_config):
    """Returns an error string if `defines` would reach the compiler too late.

    `-D` values are consumed by the front end during constant evaluation —
    `String.fromEnvironment` and friends resolve there, not at run time. When
    `main` is a pre-built kernel (signalled by a `None` `package_config`) the
    front end has already run, and `dart compile` accepts `-D` and silently
    ignores it: no error, no warning, just the default value baked into the
    output. Environment declarations for a kernel input have to go to whatever
    action produced that kernel.

    Args:
        defines: Environment declarations destined for this action.
        package_config: The `package_config.json` File, or None when `main` is
            a pre-built `.dill`.

    Returns:
        An error string, or None when the combination is sound.
    """
    if defines and package_config == None:
        return ("dart_compile_action: `defines` %s cannot be applied to a " +
                "pre-built kernel — constant evaluation already happened in " +
                "the action that produced it. Pass them to that action " +
                "instead (e.g. `gen_kernel_native_assets_action`).") % defines
    return None

def compile_quiet_flags(compile_mode):
    """Returns the flags that keep `dart compile` from writing to stdout.

    `exe` and `aot-snapshot` print `Generated: <output path>` on success, and
    Bazel echoes any action output, so every build would show a sandbox path.
    Errors still print. The other modes have no flag that silences them.

    Args:
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").

    Returns:
        A list of flag strings.
    """
    if compile_mode in ("exe", "aot-snapshot"):
        return ["--verbosity=error"]
    return []

def get_compilation_mode_flags(ctx, compile_mode):
    """Returns compiler flags for the current Bazel compilation mode.

    Args:
        ctx: The rule context (used to read ctx.var["COMPILATION_MODE"]).
        compile_mode: The Dart compile mode ("exe", "aot-snapshot", "kernel", "jit-snapshot").

    Returns:
        A list of flag strings.
    """
    bazel_mode = ctx.var["COMPILATION_MODE"]

    if bazel_mode == "dbg":
        # `dart compile kernel` rejects `--enable-asserts`: a kernel file
        # retains asserts and the invoking VM decides whether to enable them
        # (dart_test's runner always passes `--enable-asserts` at runtime).
        if compile_mode == "kernel":
            return []
        return ["--enable-asserts"]
    elif bazel_mode == "opt":
        if compile_mode in ("exe", "aot-snapshot"):
            return ["--extra-gen-snapshot-options=--optimization_level=2"]
        else:
            return []
    else:
        # fastbuild: no extra flags
        return []

# `dart_compile_flags` that the Dart front end consumes. A source compile runs
# the front end in `gen_kernel`, so these go there; the rest go to `dart compile`.
FRONT_END_VALUE_FLAGS = ["--enable-experiment", "-D", "--define"]
FRONT_END_SWITCHES = ["--enable-asserts", "--no-embed-sources", "--embed-sources"]

def split_compile_flags(flags):
    """Splits `dart_compile_flags` between the front end and `dart compile`.

    A front-end flag is `--enable-experiment=<name>`, a define (`-D<KEY=VALUE>`,
    `--define=<KEY=VALUE>`, or `-D` or `--define` with the define as the next
    flag), or `--enable-asserts`. Every other flag is a back-end flag. The
    front-end flags come back in the one-flag form that `gen_kernel` reads.

    Args:
        flags: The list of flag strings from `dart_compile_flags`.

    Returns:
        A struct with `front_end` and `backend` lists, and `error`: a message
        for a value flag with no value, or None.
    """
    front_end = []
    backend = []
    skip_next = False
    for i, flag in enumerate(flags):
        if skip_next:
            skip_next = False
            continue
        if flag in FRONT_END_VALUE_FLAGS:
            if i + 1 >= len(flags):
                return struct(
                    front_end = front_end,
                    backend = backend,
                    error = "`%s` in dart_compile_flags has no value" % flag,
                )
            value = flags[i + 1]
            skip_next = True
            if flag == "--enable-experiment":
                front_end.append("--enable-experiment=" + value)
            else:
                front_end.append("-D" + value)
        elif flag in FRONT_END_SWITCHES or flag.startswith("--enable-experiment=") or (flag.startswith("-D") and len(flag) > 2):
            front_end.append(flag)
        elif flag.startswith("--define="):
            front_end.append("-D" + flag[len("--define="):])
        else:
            backend.append(flag)
    return struct(front_end = front_end, backend = backend, error = None)

def has_comma_define_flag(flags):
    """Whether any `-D`/`--define` flag in `flags` carries a comma in its value.

    `gen_kernel` splits `-D`/`--define` values on commas, so a comma-containing
    value only survives when the compile runs the toolchain's patched snapshot
    (see `comma_patch.dart`). `split_compile_flags` normalizes every define to
    the one-flag `-D<value>` form, so only that form (and the `--define=<value>`
    form a caller may pass through) is inspected: a comma in any other flag
    never reaches the front end's define splitting.

    Args:
        flags: Flag strings bound for `gen_kernel` (the `extra_flags` of a
            whole-program action).

    Returns:
        True when a `-D<value>` or `--define=<value>` entry contains a comma.
    """
    for flag in flags:
        if flag.startswith("-D") and len(flag) > 2 and "," in flag[2:]:
            return True
        if flag.startswith("--define=") and "," in flag[len("--define="):]:
            return True
    return False

def jit_tool_entry(jit_tool_files):
    """The entry source of the JIT tool bundle.

    The `_jit_tool` attribute carries every source the tool imports, and the
    actions stage them all beside each other so the entry's relative imports
    resolve; the entry itself is picked by basename.

    Args:
        jit_tool_files: The `_jit_tool` files.

    Returns:
        The `app_jit_snapshot.dart` entry File.
    """
    for f in jit_tool_files:
        if f.basename == "app_jit_snapshot.dart":
            return f
    fail("dart_compile_action: the `_jit_tool` bundle names no `app_jit_snapshot.dart` entry")

def _jit_snapshot_action(ctx, dart_sdk_info, jit_tool, main, output, enable_asserts, comma_patch = None, fallback_allowed = False):
    """Trains the app-JIT snapshot of a kernel at its keyed absolute path.

    `dart compile jit-snapshot` trains in the action's own directory, so the
    absolute path of the sandbox ends up in the snapshot. `jit_tool` trains at
    the keyed path for this output (`--train-key=`, from the output's
    root-relative path), with the flags that keep the
    snapshot the same from build to build. See `app_jit_snapshot.dart`. A
    program whose own training run is not deterministic (it reads the clock,
    random numbers, or files outside the build) still differs between builds.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        jit_tool: The JIT tool sources: the `app_jit_snapshot.dart` entry and
            every source it imports. The entry runs; the rest land beside it
            in the sandbox, so the entry's relative imports resolve. Required
            whenever `jit_tool` runs.
        comma_patch: The `comma_patch.dart` File the tool imports. It lands
            beside the tool in the sandbox, so the tool's relative import
            resolves. Required whenever `jit_tool` runs.
        main: The kernel File to train on, with no program arguments.
        output: The `.jit` File to produce.
        enable_asserts: Whether the training run enables asserts.
        fallback_allowed: Whether the training may fall back to a private
            scratch directory when the keyed training path is unavailable
            (from `//dart:jit_snapshot_fallback`). Passed on the command line,
            so builds that allow the fallback and builds that do not have
            different action keys. With the fallback allowed the action also
            carries the `no-cache` execution requirement, so a
            fallback-trained snapshot is never uploaded to or served from a
            disk or remote cache; without it the action carries no execution
            requirements, as before. Either way a fallback-trained snapshot
            stays cached under the same action key (in the local action cache
            and the output tree) until `bazel clean`.
    """
    lock_setting = getattr(ctx.attr, "_jit_lock_timeout", None)
    lock_timeout_secs = lock_setting[BuildSettingInfo].value if lock_setting != None else JIT_SNAPSHOT_LOCK_TIMEOUT_DEFAULT
    if lock_timeout_secs <= 0:
        fail("dart_compile_action: `//dart:jit_snapshot_lock_timeout` must be above 0, got %r" % lock_timeout_secs)
    dart_bin = dart_sdk_info.dart
    dartvm = sdk_dartvm(dart_sdk_info)
    pkg_cfg = ctx.actions.declare_file(output.basename + ".jit_package_config.json")
    ctx.actions.write(
        output = pkg_cfg,
        content = '{"configVersion": 2, "packages": []}\n',
    )
    args = ctx.actions.args()
    args.add(pkg_cfg, format = "--packages=%s")
    args.add(jit_tool_entry(jit_tool))
    args.add(dart_bin, format = "--dart=%s")
    if dartvm != None:
        args.add(dartvm, format = "--dartvm=%s")
    args.add(output, format = "--snapshot=%s")
    args.add("--train-key=" + jit_train_key(output.short_path))
    if lock_timeout_secs != JIT_SNAPSHOT_LOCK_TIMEOUT_DEFAULT:
        args.add("--lock-timeout=%d" % lock_timeout_secs)
    if enable_asserts:
        args.add("--enable-asserts")
    if fallback_allowed:
        args.add("--fallback-allowed")
    args.add("--env=TMPDIR=.")
    args.add("--env=HOME=.")
    args.add(main, format = "--copy=input.dill=%s")
    args.add("--")
    args.add("input.dill")
    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = jit_tool + [pkg_cfg, dart_bin, main] + ([dartvm] if dartvm != None else []) + ([comma_patch] if comma_patch != None else []),
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = [output],
        mnemonic = "DartJitSnapshot",
        progress_message = "Compiling Dart jit-snapshot %s" % ctx.label,
        env = writable_home_env(dart_bin, output),
        # With the fallback allowed the trained bytes may be this host's
        # private-scratch ones, so the action must never reach a shared cache.
        # Without it no dict is built and the action is as before.
        execution_requirements = {"no-cache": "1"} if fallback_allowed else None,
    )

def _kernel_comma_snapshot(ctx, dart_sdk_info, tools, defines, extra_flags, jit_tool):
    """Selects the patched `gen_kernel` snapshot for comma defines. Returns (gen_snapshot, comma_sources)."""

    # A comma-containing value only survives the frontend when `gen_kernel`
    # runs the toolchain's patched snapshot: the frontend splits `-D` values
    # on commas. The patched snapshot is a declared action output taken as a
    # tool input, so the patch runs once per SDK, not once per compile. The
    # wrapper consumes the marker below and refuses comma defines without it,
    # so a comma compile can never silently run the pristine snapshot. A
    # comma `-D` in `dart_compile_flags` takes the same path: those flags all
    # reach `gen_kernel` (see `dart_compile_action`), so they need the patch
    # exactly like `defines` do.
    comma_defines = has_comma_define(defines)
    comma_flags = has_comma_define_flag(extra_flags)
    comma_sources = []
    if comma_defines:
        comma_sources.append("`defines` %s" % (defines,))
    if comma_flags:
        comma_sources.append("`dart_compile_flags` %s" % (extra_flags,))
    gen_snapshot = None
    if comma_sources:
        comma_source = " and ".join(comma_sources)
        gen_snapshot = tools.patched_gen_kernel
        if gen_snapshot == None:
            fail(("dart_compile_action: target %s passes comma-containing " +
                  "%s, but the SDK (Dart %s) declares no patched " +
                  "`gen_kernel` snapshot, so no compile can keep the commas. " +
                  "Use an SDK whose snapshot `comma_patch.dart` knows how " +
                  "to patch.") % (ctx.label, comma_source, dart_sdk_info.version))
        if not jit_tool:
            fail(("dart_compile_action: target %s passes comma-containing " +
                  "%s, but no `jit_tool` wrapper runs its " +
                  "`gen_kernel` step to authorize the patched snapshot.") %
                 (ctx.label, comma_source))
    return gen_snapshot, comma_sources

def _kernel_front_args(ctx, dart_sdk_info, st, aot, enable_asserts, extra_flags, product, output):
    """Builds the `gen_kernel` args and outputs.

    Returns (args, outputs, tools, gen_snapshot, comma_sources): the args and
    outputs for the `gen_kernel` run, the SDK kernel tools, the patched
    `gen_kernel` snapshot (or None), and the comma-define sources authorizing
    it (or None).
    """
    tools = find_sdk_kernel_tools(dart_sdk_info)
    platform = tools.product_platform_dill if product else tools.platform_dill
    gen_snapshot, comma_sources = _kernel_comma_snapshot(ctx, dart_sdk_info, tools, st.defines, extra_flags, st.jit_tool)
    args = gen_kernel_args(ctx, tools, platform, st.package_config, gen_kernel_snapshot = gen_snapshot)
    args.add("-Ddart.vm.product=" + ("true" if product else "false"))
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    if aot:
        args.add("--aot")
        args.add("--tfa")
        args.add("--no-embed-sources")
        if st.target_os:
            args.add("--target-os", st.target_os)
    elif not st.embed_sources:
        args.add("--no-embed-sources")
    if st.native_assets_yaml != None:
        args.add("--native-assets", st.native_assets_yaml)
    if enable_asserts:
        args.add("--enable-asserts")
    for d in st.defines:
        args.add("-D" + d)

    outputs = [output]

    args.add_all(extra_flags)
    args.add("-o", output)
    args.add(STABLE_SCHEME + ":///" + stable_entry_path(ctx, st.main_path if st.main_path != None else st.main.path))
    return args, outputs, tools, gen_snapshot, comma_sources

def _kernel_run_wrapper(ctx, dart_sdk_info, st, tools, args, outputs, gen_snapshot, comma_sources):
    """Runs `gen_kernel` through the isolated-filesystem wrapper."""
    dartvm = sdk_dartvm(dart_sdk_info)
    wrapper_args = ctx.actions.args()
    wrapper_args.add(st.package_config, format = "--packages=%s")
    wrapper_args.add(jit_tool_entry(st.jit_tool))
    wrapper_args.add("--gen-kernel")
    wrapper_args.add(tools.dartaotruntime)
    if comma_sources:
        # After `dartaotruntime`: `_runGenKernel` takes `argv.first` as the
        # runtime positionally and consumes this marker in its flag loop,
        # never forwarding it to `gen_kernel`.
        wrapper_args.add("--comma-patched-snapshot")
    input_srcs_args = ctx.actions.args()
    input_srcs_args.use_param_file("--input-sources-file=%s", use_always = True)
    input_srcs_args.set_param_file_format("multiline")
    input_srcs_args.add_all(depset([st.main] + st.srcs))
    direct = [st.main, st.package_config] + st.srcs
    if st.native_assets_yaml != None:
        direct.append(st.native_assets_yaml)
    direct.extend(st.jit_tool)
    if st.comma_patch != None:
        direct.append(st.comma_patch)
    if gen_snapshot != None:
        # The patched snapshot lives in `bazel-out`, outside the SDK file
        # sets, so it is declared explicitly. Builds without comma defines
        # never take it and never run the action that produces it.
        direct.append(gen_snapshot)
    if dartvm != None:
        direct.append(dartvm)
    else:
        direct.append(dart_sdk_info.dart)
    ctx.actions.run(
        executable = dartvm if dartvm != None else dart_sdk_info.dart,
        arguments = [wrapper_args, input_srcs_args, args],
        inputs = depset(
            direct = direct,
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = outputs,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = writable_home_env(dart_sdk_info.dart, outputs[0]),
    )

def _kernel_run_direct(ctx, dart_sdk_info, tools, args, direct, outputs):
    """Runs `gen_kernel` directly via `dartaotruntime`."""
    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = direct,
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = outputs,
        mnemonic = "DartKernel",
        progress_message = "Compiling Dart kernel %s" % ctx.label,
        env = writable_home_env(dart_sdk_info.dart, outputs[0]),
    )

def _kernel_action(ctx, dart_sdk_info, st, aot, enable_asserts, extra_flags, product, output):
    """Runs `gen_kernel` over a source entrypoint, with stable URIs.

    `dart compile` reads its package config and entrypoint as file paths and
    records them as absolute `file:` URIs. `gen_kernel` takes the scheme
    described in `gen_kernel_args`, so the kernel names every library by its
    repository path. Mode flags that belong to the front end go here: `--aot
    --tfa` for the modes that tree-shake, `dart.vm.product` and sanitizer
    defines matching `dart compile`, and `--enable-asserts`, which is
    constant-folded or dropped while the front end runs.

    The remaining inputs (entrypoint, sources, package config, defines, target
    OS, tools, native assets, source embedding) travel in `st`, the struct
    `dart_compile_action` threads through its helpers. The kernel step never
    records `@RecordUse` uses: only the `dart compile` step of the
    tree-shaking modes does.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        st: The threaded compile struct (see `dart_compile_action`).
        aot: Whether to produce an AOT kernel (`--aot --tfa`).
        enable_asserts: Whether to pass `--enable-asserts`.
        extra_flags: Flags for `gen_kernel` itself, appended last. A
            comma-containing `-D`/`--define` among them takes the same
            comma-safe path as `defines` (the toolchain's patched snapshot
            plus the `--comma-patched-snapshot` marker).
        product: Whether the kernel is for a product runtime: an AOT snapshot or
            executable, or a `dart compile kernel` file. False for the JIT VM
            that builds a `jit-snapshot`.
        output: The kernel File to write.
    """
    args, outputs, tools, gen_snapshot, comma_sources = _kernel_front_args(
        ctx,
        dart_sdk_info,
        st,
        aot,
        enable_asserts,
        extra_flags,
        product,
        output,
    )

    if st.jit_tool:
        _kernel_run_wrapper(ctx, dart_sdk_info, st, tools, args, outputs, gen_snapshot, comma_sources)
        return

    direct = [st.main, st.package_config] + st.srcs
    if st.native_assets_yaml != None:
        direct.append(st.native_assets_yaml)
    _kernel_run_direct(ctx, dart_sdk_info, tools, args, direct, outputs)

_SUPPORTED_CROSS_TARGET_PAIRS = {
    ("linux", "x64"): True,
    ("linux", "arm64"): True,
    ("linux", "riscv64"): True,
    ("linux", "arm"): True,
}

def cross_target_error(target_os, target_arch):
    """Returns an error string if `(target_os, target_arch)` is an invalid cross-compile target.

    Args:
        target_os: Target OS string (or `""` for native).
        target_arch: Target architecture string (or `""` for native).

    Returns:
        An error message string, or `None` when native or a supported cross target.
    """
    if bool(target_os) != bool(target_arch):
        return "dart_compile_action: target_os and target_arch must both be set or both be empty (got target_os=%r, target_arch=%r)" % (
            target_os,
            target_arch,
        )
    if target_os and (target_os, target_arch) not in _SUPPORTED_CROSS_TARGET_PAIRS:
        return "dart_compile_action: unsupported cross-compilation target (%s, %s); supported targets are linux/{x64,arm64,riscv64,arm}" % (
            target_os,
            target_arch,
        )
    return None

def _compile_validate(ctx, cfg):
    """Fails on invalid cross targets, cross jit-snapshot, late defines, unrecordable modes, and tool mismatches."""
    cross_err = cross_target_error(cfg.target_os, cfg.target_arch)
    if cross_err != None:
        fail(cross_err)
    if cfg.compile_mode == "jit-snapshot" and (cfg.target_os or cfg.target_arch):
        fail(
            ("dart_compile_action: target %s requested cross-compilation target " +
             "(%s, %s) with `compile_mode = \"jit-snapshot\"`; jit-snapshot is " +
             "host-only because it trains on the build machine's Dart VM and has " +
             "no target OS/CPU flags; use `exe` or `aot-snapshot` to cross-compile.") % (
                ctx.label,
                cfg.target_os,
                cfg.target_arch,
            ),
        )
    stage_err = defines_stage_error(cfg.defines, cfg.package_config)
    if stage_err != None:
        fail(stage_err)
    if cfg.recorded_uses != None and cfg.compile_mode not in RECORDING_COMPILE_MODES:
        fail("dart_compile_action: `dart compile %s` records no uses." % cfg.compile_mode)
    if cfg.jit_tool and cfg.comma_patch == None:
        fail("dart_compile_action: target %s passes `jit_tool` without the " +
             "`comma_patch.dart` File it imports, so no action could run it " +
             "from source. Pass `comma_patch` alongside `jit_tool`." % ctx.label)

def _compile_split_flags(extra_flags, package_config):
    """Splits extra flags between the front end and `dart compile`. Returns (front_end_flags, backend_flags)."""

    # The front end consumes its flags, so they go to `gen_kernel` for a source
    # entrypoint. `kernel` is the `gen_kernel` stage itself and gets them all; a
    # pre-built kernel has no front end to receive them.
    if package_config == None:
        return [], extra_flags
    split = split_compile_flags(extra_flags)
    if split.error != None:
        fail(split.error)
    return split.front_end, split.backend

def _compile_kernel_mode(ctx, dart_sdk_info, st):
    """Runs the `kernel` mode's lone `gen_kernel` step."""
    _kernel_action(
        ctx = ctx,
        dart_sdk_info = dart_sdk_info,
        st = st,
        aot = False,
        enable_asserts = False,
        extra_flags = st.front_end_flags + st.backend_flags,
        product = True,
        output = st.output,
    )

def _compile_front_end(ctx, dart_sdk_info, st):
    """Runs the front-end `gen_kernel` step. Returns the kernel File feeding `dart compile`."""

    # The front end runs once, here, with the stable URIs. Its kernel is the
    # input of the `dart compile` step below.
    aot = st.compile_mode in RECORDING_COMPILE_MODES
    kernel = ctx.actions.declare_file(st.output.basename + ".dill")
    _kernel_action(
        ctx = ctx,
        dart_sdk_info = dart_sdk_info,
        st = st,
        aot = aot,
        enable_asserts = "--enable-asserts" in st.mode_flags and "--enable-asserts" not in st.front_end_flags,
        extra_flags = st.front_end_flags,
        product = st.compile_mode != "jit-snapshot",
        output = kernel,
    )
    return kernel

def _compile_jit_train(ctx, dart_sdk_info, st, compile_main, compile_main_path):
    """Trains the app-JIT snapshot when eligible. Returns True when the output is produced."""

    # The app-JIT snapshot is trained by the scratch-directory tool when it has
    # one, and on a POSIX host (on Windows the mode uses `dart compile
    # jit-snapshot`, so the snapshot keeps the sandbox path).
    if st.compile_mode != "jit-snapshot" or not st.jit_tool or compile_main_path != None or dart_sdk_info.dart.basename.endswith(".exe"):
        return False
    if st.backend_flags:
        fail("dart_compile_flags %s do not apply to jit-snapshot" % st.backend_flags)
    _jit_snapshot_action(
        ctx = ctx,
        dart_sdk_info = dart_sdk_info,
        jit_tool = st.jit_tool,
        comma_patch = st.comma_patch,
        main = compile_main,
        output = st.output,
        enable_asserts = st.enable_asserts,
        fallback_allowed = st.jit_snapshot_fallback,
    )
    return True

def _compile_aot_wrapper(ctx, dart_sdk_info, st, compile_main, compile_main_path, compile_srcs):
    """Compiles exe/aot/jit via the isolated-filesystem wrapper. Returns True when it ran."""
    if st.compile_mode not in ("exe", "aot-snapshot", "jit-snapshot") or not st.jit_tool or compile_main_path != None:
        return False
    dart_bin = dart_sdk_info.dart
    pkg_cfg = st.package_config
    if pkg_cfg == None:
        pkg_cfg = ctx.actions.declare_file(st.output.basename + ".aot_package_config.json")
        ctx.actions.write(output = pkg_cfg, content = "{\"configVersion\": 2, \"packages\": []}\n")
    args = ctx.actions.args()
    args.add(pkg_cfg, format = "--packages=%s")
    args.add(jit_tool_entry(st.jit_tool))
    args.add("--aot")
    args.add(dart_bin, format = "--dart=%s")
    args.add(st.compile_mode, format = "--mode=%s")
    if st.target_os:
        args.add("--target-os", st.target_os)
    if st.target_arch:
        args.add("--target-arch", st.target_arch)
    if st.cross_gen_snapshot != None:
        args.add(st.cross_gen_snapshot, format = "--gen-snapshot=%s")
    if st.cross_dartaotruntime != None:
        args.add(st.cross_dartaotruntime, format = "--dartaotruntime=%s")
    args.add_all(compile_quiet_flags(st.compile_mode))
    args.add_all(st.mode_flags)
    if st.enable_asserts and "--enable-asserts" not in st.mode_flags and "--enable-asserts" not in st.backend_flags:
        args.add("--enable-asserts")
    outputs = [st.output]
    if st.recorded_uses != None:
        args.add(st.recorded_uses, format = "--recorded-uses=%s")
        outputs.append(st.recorded_uses)
    args.add_all(st.backend_flags)
    args.add("-o", st.output)
    args.add(compile_main)
    direct_inputs = st.jit_tool + [pkg_cfg, compile_main] + compile_srcs
    if st.comma_patch != None:
        direct_inputs.append(st.comma_patch)
    if st.cross_gen_snapshot != None:
        direct_inputs.append(st.cross_gen_snapshot)
    if st.cross_dartaotruntime != None:
        direct_inputs.append(st.cross_dartaotruntime)
    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = outputs,
        mnemonic = "DartCompile",
        progress_message = "Compiling Dart %s %s" % (st.compile_mode, ctx.label),
        env = writable_home_env(dart_bin, st.output),
    )
    return True

def _compile_dart_compile(ctx, dart_sdk_info, st, compile_main, compile_main_path, compile_srcs):
    """Runs the plain `dart compile` action."""
    dart_bin = dart_sdk_info.dart
    args = ctx.actions.args()
    args.add("compile")
    args.add(st.compile_mode)
    args.add_all(compile_quiet_flags(st.compile_mode))

    # Cross-compilation flags (only valid for exe and aot-snapshot modes)
    if st.target_os and (st.compile_mode == "exe" or st.compile_mode == "aot-snapshot"):
        args.add("--target-os", st.target_os)
    if st.target_arch and (st.compile_mode == "exe" or st.compile_mode == "aot-snapshot"):
        args.add("--target-arch", st.target_arch)

    # Compilation mode defaults
    args.add_all(st.mode_flags)
    if st.enable_asserts and "--enable-asserts" not in st.mode_flags and "--enable-asserts" not in st.backend_flags:
        args.add("--enable-asserts")

    outputs = [st.output]
    if st.recorded_uses != None:
        args.add(st.recorded_uses, format = "--recorded-uses=%s")
        outputs.append(st.recorded_uses)

    # Per-target extra flags (last, so they can override defaults)
    args.add_all(st.backend_flags)

    args.add("-o", st.output)
    args.add(compile_main_path if compile_main_path != None else compile_main)

    env = writable_home_env(dart_bin, st.output)

    direct_inputs = [compile_main] + compile_srcs
    if st.cross_gen_snapshot != None and st.compile_mode in ("exe", "aot-snapshot"):
        direct_inputs.append(st.cross_gen_snapshot)
    if st.cross_dartaotruntime != None and st.compile_mode in ("exe", "aot-snapshot"):
        direct_inputs.append(st.cross_dartaotruntime)

    ctx.actions.run(
        executable = dart_bin,
        arguments = [args],
        inputs = depset(
            direct = direct_inputs,
            transitive = [dart_sdk_info.compile_files],
        ),
        outputs = outputs,
        mnemonic = "DartCompile",
        progress_message = "Compiling Dart %s %s" % (st.compile_mode, ctx.label),
        env = env,
    )

def dart_compile_action(ctx, dart_sdk_info, cfg):
    """Creates the actions that compile a Dart entrypoint in `compile_mode`.

    A source entrypoint (one with a `package_config`) is first compiled to a
    kernel by `gen_kernel`, which names every library by a stable URI (see
    `gen_kernel_args`). The `dart compile` step then works from that kernel, so
    no output embeds the sandbox it was built in. The `kernel` mode is the
    `gen_kernel` step alone. A pre-built kernel `main` is compiled directly.

    The per-target inputs travel together in `cfg`, and the values derived
    from them (the flag split, the compilation-mode flags, the cross-compile
    snapshots) join them in `st`: one struct, built once here and threaded
    through the helpers below, so no function takes a long parameter list.

    Args:
        ctx: The rule context.
        dart_sdk_info: The `DartSdkInfo` of the toolchain.
        cfg: A struct with the compile inputs. `main` is the main File to add
            to action inputs (usually the entrypoint `.dart` File; an
            assembled directory when `main_path` points inside it). `srcs` is
            the list of all source Files needed for compilation (direct +
            transitive). `package_config` is the package_config.json File, or
            None when `main` is a pre-built kernel. `output` is the output
            File to produce. `compile_mode` is the compilation mode ("exe",
            "aot-snapshot", "kernel", "jit-snapshot"). `target_os` is the
            cross-compilation target OS (e.g. "linux"), empty for native.
            `target_arch` is the cross-compilation target architecture (e.g.
            "x64"), empty for native. `extra_flags` holds additional compiler
            flags (from the dart_compile_flags attribute): `kernel` passes
            them all to `gen_kernel`, the stage that produces that mode; for a
            source entrypoint in the other modes, the front-end flags (see
            `split_compile_flags`) go to `gen_kernel` and the rest to `dart
            compile`; a pre-built kernel passes them all to `dart compile`.
            `defines` holds environment declarations; each entry becomes a -D
            flag, given to the `gen_kernel` step, and a comma-containing entry
            runs the toolchain's patched `gen_kernel` snapshot. `main_path`
            is the optional path string to pass as the compile target instead
            of `main.path` (e.g. a path inside an assembled `main` directory).
            `recorded_uses` is the optional output File for the uses of
            `@RecordUse` definitions the compiler records (`--recorded-uses`);
            only the `exe` and `aot-snapshot` modes record. `jit_tool` lists
            the JIT tool sources: the `app_jit_snapshot.dart` entry and every
            source it imports. The `jit-snapshot` mode trains with the entry
            when given, so the snapshot is reproducible; without it, and on
            a Windows host, the mode uses `dart compile jit-snapshot`, so the
            snapshot keeps the sandbox path. `comma_patch` is the
            `comma_patch.dart` File the tool imports, staged beside it in
            every action that runs it from source; required whenever
            `jit_tool` is passed. `native_assets_yaml` is the optional
            `native_assets.yaml` File. `embed_sources` tells whether non-AOT
            kernels embed source text. `jit_snapshot_fallback` tells whether a
            `jit-snapshot` training may fall back to a private scratch
            directory when the keyed training path is unavailable (from
            `//dart:jit_snapshot_fallback`); it reaches the snapshot action's
            command line, so builds that allow the fallback and builds that do
            not have different action keys.
    """
    _compile_validate(ctx, cfg)

    front_end_flags, backend_flags = _compile_split_flags(cfg.extra_flags, cfg.package_config)

    mode_flags = get_compilation_mode_flags(ctx, cfg.compile_mode)
    enable_asserts = (
        "--enable-asserts" in mode_flags or
        "--enable-asserts" in front_end_flags or
        "--enable-asserts" in backend_flags
    )

    is_cross = bool(cfg.target_os) or bool(cfg.target_arch)
    cross_gen_snapshot = getattr(dart_sdk_info, "cross_gen_snapshot", None) if is_cross else None
    cross_dartaotruntime = getattr(dart_sdk_info, "cross_dartaotruntime", None) if is_cross else None

    st = struct(
        main = cfg.main,
        srcs = cfg.srcs,
        package_config = cfg.package_config,
        output = cfg.output,
        compile_mode = cfg.compile_mode,
        target_os = cfg.target_os,
        target_arch = cfg.target_arch,
        defines = cfg.defines,
        main_path = cfg.main_path,
        recorded_uses = cfg.recorded_uses,
        jit_tool = cfg.jit_tool,
        comma_patch = cfg.comma_patch,
        native_assets_yaml = cfg.native_assets_yaml,
        embed_sources = cfg.embed_sources,
        jit_snapshot_fallback = cfg.jit_snapshot_fallback,
        front_end_flags = front_end_flags,
        backend_flags = backend_flags,
        mode_flags = mode_flags,
        enable_asserts = enable_asserts,
        cross_gen_snapshot = cross_gen_snapshot,
        cross_dartaotruntime = cross_dartaotruntime,
    )

    compile_main = st.main
    compile_main_path = st.main_path
    compile_srcs = st.srcs
    if st.package_config != None:
        if st.compile_mode == "kernel":
            _compile_kernel_mode(ctx, dart_sdk_info, st)
            return

        compile_main = _compile_front_end(ctx, dart_sdk_info, st)
        compile_main_path = None
        compile_srcs = []

    if _compile_jit_train(ctx, dart_sdk_info, st, compile_main, compile_main_path):
        return

    if _compile_aot_wrapper(ctx, dart_sdk_info, st, compile_main, compile_main_path, compile_srcs):
        return

    _compile_dart_compile(ctx, dart_sdk_info, st, compile_main, compile_main_path, compile_srcs)
