"""The `dart_analyzer_summary` aspect: an analyzer summary of each Dart package.

Under `//dart:analyzer_summaries`, the `dart_analyze` aspect checks a target's
own files against the summaries of its dependencies, rather than against their
source. This aspect makes those summaries. It propagates along `deps` and
`library`, and `dart_analyze` requires it, so every dependency of an analyzed
target carries one.

A summary is the declarations of a package's libraries, and what constants they
need. It holds no function bodies, so a body edit leaves a package's summary
unchanged and its dependents are not checked again. It is built by the
`summarize` mode of `//dart/private/tools:analyzer_summary`, with the pinned
`package:analyzer`.

A summary refers to the SDK's libraries, which no package's summary holds, so
every summary-mode action also reads the SDK's own summary, one per SDK,
`analyzer_sdk_summary`.

With the flag off the aspect declares no actions and provides empty values, so
a build without the flag is as it was.
"""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//dart:providers.bzl", "DartInfo")
load("//dart/private:common.bzl", "generate_package_config")

# Summaries are built on the build machine, with the exec tools SDK, the type
# the codegen rules and `dart_analyze` use for the same reason.
_TOOLCHAIN = "//dart:exec_tools_toolchain_type"

DartAnalyzerSummaryInfo = provider(
    doc = "A target's analyzer summaries, for `dart_analyze` in analyzer-summary mode.",
    fields = {
        "summary": "File or None: the summary of this target's own libraries. None when it has none, or the flag is off.",
        "transitive_summaries": "depset[File]: the summaries of this target and of every target it depends on.",
        "packages": "depset[str]: the keys (see `package_key`) of this target's own package and of every package its dependencies carry. A package in a closure that is missing here has no summary, so its dependents are analyzed from source.",
    },
)

def package_key(info):
    """Returns the key that identifies a package record: its name and root.

    Args:
      info: A `DartInfo`, or a `DartPackageInfo` record.

    Returns:
      A string that identifies the package. `dart_analyze` matches a closure's
      packages against the keys its dependencies cover.
    """
    return "%s|%s" % (info.package_name, info.lib_root)

def sdk_root_path(dart_sdk_info):
    """Returns the exec-root path of the SDK root that holds `dart`'s `bin/`.

    Args:
      dart_sdk_info: The `DartSdkInfo` of the exec tools toolchain.

    Returns:
      The SDK's root directory, as an exec-root-relative path.
    """
    return dart_sdk_info.dart.path.rsplit("/", 2)[0]

def _analyzer_sdk_summary_impl(ctx):
    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    summary = ctx.actions.declare_file(ctx.label.name + ".sum")
    args = ctx.actions.args()
    args.add("sdk")
    args.add("--sdk", sdk_root_path(dart_sdk_info))
    args.add("--out", summary)
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = dart_sdk_info.analyze_files,
        outputs = [summary],
        mnemonic = "DartAnalyzerSdkSummary",
        progress_message = "Summarizing the Dart SDK for analysis",
    )
    return [DefaultInfo(files = depset([summary]))]

analyzer_sdk_summary = rule(
    implementation = _analyzer_sdk_summary_impl,
    attrs = {
        "_tool": attr.label(
            default = "//dart/private/tools:analyzer_summary",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
    doc = """The summary of the SDK's own libraries, which every summary-mode action reads.

A dependency's summary refers to the SDK libraries it uses, and those are not in
any package's summary, so a summary-mode action needs this one as well. Built
once per SDK; `dart/private/BUILD.bazel` declares the instance the aspects use.
""",
)

def closure_attrs(ctx):
    """Returns the targets a rule's closure is built from: its `deps`, and its `library`.

    The aspect propagates along the same two attributes, so every target here
    carries the provider, unless it is not a Dart target at all.

    Args:
      ctx: The rule or aspect context.

    Returns:
      A list of `Target`s.
    """
    targets = list(getattr(ctx.rule.attr, "deps", []))
    library = getattr(ctx.rule.attr, "library", None)
    if library != None:
        targets.append(library)
    return targets

def _own_sources(info, files):
    """Returns the `.dart` files of `files` that are `info`'s package's `lib/` files.

    Args:
      info: The target's `DartInfo`.
      files: Candidate `File`s, typically the target's `DefaultInfo` files.

    Returns:
      The package's library files, in the order given.
    """
    if not info.package_name:
        return []
    prefix = (info.lib_root + "/lib/") if info.lib_root else "lib/"
    return [f for f in files if f.extension == "dart" and f.short_path.startswith(prefix)]

def _package_uri(info, f):
    """Returns the `package:` URI of library `f` of `info`'s own package."""
    prefix = (info.lib_root + "/lib/") if info.lib_root else "lib/"
    return "package:%s/%s" % (info.package_name, f.short_path[len(prefix):])

def _dart_analyzer_summary_impl(target, ctx):
    if DartInfo not in target:
        return []
    deps = closure_attrs(ctx)
    dependencies = depset(transitive = [
        d[DartAnalyzerSummaryInfo].transitive_summaries
        for d in deps
        if DartAnalyzerSummaryInfo in d
    ])
    info = target[DartInfo]
    if not ctx.attr._enabled[BuildSettingInfo].value:
        return [DartAnalyzerSummaryInfo(summary = None, transitive_summaries = depset(), packages = depset())]

    # Every target contributes its own package, summarized or not, so a package
    # with no library of its own is not mistaken for one that is missing.
    packages = depset(
        [package_key(info)],
        transitive = [d[DartAnalyzerSummaryInfo].packages for d in deps if DartAnalyzerSummaryInfo in d],
    )
    srcs = _own_sources(info, target[DefaultInfo].files.to_list())
    if not srcs:
        return [DartAnalyzerSummaryInfo(summary = None, transitive_summaries = dependencies, packages = packages)]

    name = ctx.label.name + ".dart_analyzer_summary"
    summary = ctx.actions.declare_file(name + ".sum")
    config = ctx.actions.declare_file(name + ".package_config.json")

    # The closure's roots, not its sources: a dependency's libraries come from
    # its summary, so its files are not read and need not be inputs.
    ctx.actions.write(
        output = config,
        content = generate_package_config(
            info.transitive_packages.to_list(),
            info.transitive_srcs.to_list(),
            config,
        ),
    )

    dart_sdk_info = ctx.toolchains[_TOOLCHAIN].dart_sdk_info
    args = ctx.actions.args()
    args.add("summarize")
    args.add("--sdk", sdk_root_path(dart_sdk_info))
    args.add("--packages", config)
    args.add("--out", summary)
    args.add("--summary", ctx.file._sdk_summary)
    for f in srcs:
        args.add("--source", f)
        args.add("--uri", _package_uri(info, f))
    args.add_all(dependencies, before_each = "--summary")
    ctx.actions.run(
        executable = ctx.executable._tool,
        arguments = [args],
        inputs = depset(direct = srcs + [config, ctx.file._sdk_summary], transitive = [dart_sdk_info.analyze_files, dependencies]),
        outputs = [summary],
        mnemonic = "DartAnalyzerSummary",
        progress_message = "Summarizing Dart library %{label}",
    )
    return [DartAnalyzerSummaryInfo(
        summary = summary,
        transitive_summaries = depset([summary], transitive = [dependencies]),
        packages = packages,
    )]

dart_analyzer_summary = aspect(
    implementation = _dart_analyzer_summary_impl,
    # `deps` is what rules_dart builds a closure from. `library` is the one
    # other attribute that carries one: `dart_test_package` names its library
    # there, so without it a test's package closure would stop at the runner.
    attr_aspects = ["deps", "library"],
    attrs = {
        "_enabled": attr.label(
            default = "//dart:analyzer_summaries",
            providers = [BuildSettingInfo],
        ),
        "_sdk_summary": attr.label(
            default = "//dart/private:analyzer_sdk_summary_input",
            allow_single_file = True,
        ),
        "_tool": attr.label(
            default = "//dart/private:analyzer_summary_tool",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [_TOOLCHAIN],
    doc = "Summarizes each Dart package for `dart_analyze`'s analyzer-summary mode; see `//dart/private/dart_analyzer_summary.bzl`.",
)
