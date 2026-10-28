"""Repository rule for downloading a single pub.dev package."""

load("//dart/private:download.bzl", "pinned_download")
load("//dart/pub:pinned_sources.bzl", "pinned_source_error")
load("//dart/pub:pub_scan.bzl", "run_pub_archive_scan")
load("//dart/pub:yaml_parser.bzl", "parse_pubspec_sdk_constraint", "pubspec_sdk_constraint_error")
load("//dart/pub/private:build_content.bzl", "PACKAGE_FILES_ATTR_DOC", "make_dart_library_build_content")
load("//dart/pub/private:language_version.bzl", "derive_language_version")
load("//dart/pub/private:pub_symlink.bzl", "check_package_symlinks")

def pub_package_sha256_error(package_name, version, sha256):
    """Validates `sha256` for a `pub_package` target.

    Args:
        package_name: The pub.dev package name.
        version: The package version string.
        sha256: Candidate SHA-256 checksum string.

    Returns:
        An error string when `sha256` is empty or not 64 lowercase hex digits,
        or None when valid.
    """
    return pinned_source_error(
        "hosted",
        package_name,
        version,
        sha256 = sha256,
        rule = "pub_package",
    )

def _pub_package_impl(ctx):
    err = pub_package_sha256_error(
        ctx.attr.package_name,
        ctx.attr.version,
        ctx.attr.sha256,
    )
    if err:
        fail(err)

    url = "https://pub.dev/api/archives/{name}-{version}.tar.gz".format(
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )

    # Download first so the archive headers can be refused before the
    # extractor trusts them; a hard-link entry or an absolute or
    # package-escaping symlink entry fails the fetch here.
    pinned_download(
        ctx,
        url = url,
        output = "_archive.tar.gz",
        sha256 = ctx.attr.sha256.strip(),
    )
    run_pub_archive_scan(ctx, "_archive.tar.gz", ctx.attr.package_name)
    ctx.extract("_archive.tar.gz")
    ctx.delete("_archive.tar.gz")
    check_package_symlinks(ctx, ctx.attr.package_name)

    # Read the package's pubspec.yaml so we can mirror pub's per-package
    # languageVersion behaviour. This lets the analyzer apply the right
    # language semantics for packages whose SDK floor predates the running
    # Dart SDK (e.g. `state_notifier` with `sdk: ">=2.12.0"`).
    pubspec_content = ctx.read("pubspec.yaml")
    sdk_err = pubspec_sdk_constraint_error(pubspec_content, ctx.attr.package_name + "/pubspec.yaml")
    if sdk_err:
        fail(sdk_err)
    sdk_constraint = parse_pubspec_sdk_constraint(pubspec_content)
    language_version = derive_language_version(sdk_constraint)

    # Generate BUILD.bazel with a dart_library target. `deps` here names sibling
    # repositories, whose default target carries the repo's own name.
    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = ["@{dep}".format(dep = dep) for dep in ctx.attr.deps],
        language_version = language_version,
        version = ctx.attr.version,
        # A link hook is runnable by `dart_link_hook`, so it is recorded.
        link_hook = "hook/link.dart" if ctx.path("hook/link.dart").exists else "",
        package_files = ctx.attr.package_files,
    )

    ctx.file("BUILD.bazel", build_content)

pub_package = repository_rule(
    implementation = _pub_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub.dev package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive for integrity verification.",
            mandatory = True,
        ),
        "deps": attr.string_list(
            doc = "Repository names of pub packages this package depends on.",
            default = [],
        ),
        "package_files": attr.string_list(
            doc = PACKAGE_FILES_ATTR_DOC,
            default = ["pubspec.yaml", "LICENSE*"],
        ),
    },
    doc = "Downloads a pub.dev package and generates a dart_library BUILD target.",
)
