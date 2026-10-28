"""Parameter objects for the `DartInfo` constructors in `dart_info.bzl`.

`dart_info()` and `dart_analyzable_info_with_package()` both state the package
the target contributes: its name, its `lib/` root, its language version, and
its resolved version. One struct names that identity once, so the two
constructors cannot disagree about what a package is.
"""

def dart_package_identity(
        package_name,
        lib_root,
        language_version,
        version = "",
        package_files = []):
    """The package a target contributes to the build.

    Args:
      package_name: The Dart package name this target provides.
      lib_root: `short_path`-based path to the package root (parent of
        `lib/`). Empty string for the root package.
      language_version: Dart language version in `<major>.<minor>` form, or
        "" when the package states none. Required to pass — not because a
        package must have one, but because omitting the argument and stating
        `""` are different intentions that used to produce the same call. An
        absent `languageVersion` in `package_config.json` is not "no language
        version", it is *the current SDK's*, so a forgotten argument silently
        compiles the package under newer semantics than its pubspec allows.
        `""` remains a legal, meaningful value; only not answering is gone.
      version: The package's own resolved version, or "" when unknown. Only
        pub spokes know it; a hand-written `dart_library` leaves it empty.
      package_files: The package's runtime-only files: `dart_library`'s
        `data` files, which ride runfiles and never enter an action. They
        travel with the identity so `dart_info()` can record them in
        `DartInfo.package_files` without a ninth parameter of its own. Empty
        when the package ships none.

    Returns:
      A struct with those fields.
    """
    return struct(
        package_name = package_name,
        lib_root = lib_root,
        language_version = language_version,
        version = version,
        package_files = package_files,
    )
