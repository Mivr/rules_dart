"""Collectors for a package's runfiles-only files.

A package's non-`lib/` files — `pubspec.yaml`, `LICENSE`, an asset a tool
finds by walking the package root — are not compile inputs and are not
`resources`; they ride runfiles only. `DartInfo.transitive_package_files`
carries their closure, and this file is the one collector for it so every
rule that builds runfiles says so explicitly rather than folding them into
the source or resource closure by accident.

The field is read through `getattr` because it is newer than `DartInfo`
itself: a producer built against an earlier rules_dart omits it, and
`collect_code_asset_files` established that shape for exactly this reason.
"""

load("//dart:providers.bzl", "DartInfo")

def collect_transitive_package_files(deps):
    """Collect the runtime-only `data` files from DartInfo deps.

    Args:
        deps: List of targets providing DartInfo.

    Returns:
        Depset of Files from the transitive package-file closure.
    """
    return depset(
        transitive = [
            getattr(dep[DartInfo], "transitive_package_files", depset())
            for dep in deps
        ],
    )
