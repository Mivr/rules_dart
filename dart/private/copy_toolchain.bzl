"""The toolchain rule that provides the `copy_tree` tool.

`assemble_source_dir` in `source_set.bzl` copies files into a tree artifact by
running this tool. The toolchain is registered from `MODULE.bazel`, next to the
Dart SDK toolchain.
"""

def _copy_toolchain_impl(ctx):
    return [platform_common.ToolchainInfo(copy_tree = ctx.executable.tool)]

copy_toolchain = rule(
    implementation = _copy_toolchain_impl,
    doc = "Provides the `copy_tree` tool under `//dart:copy_toolchain_type`.",
    attrs = {
        "tool": attr.label(
            doc = "The `copy_tree` tool, built for the exec platform.",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
    },
)
