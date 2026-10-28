"""A member package of a multi-package `dart_library`.

One `dart_library` normally owns one package: its sources sit under one
`lib/` root and resolve as one `package:` name. A library merged over a pub
dependency cycle owns several — `dio` and `dio_web_adapter` each keep their
own name and their own `lib/` root inside one merged repository, but there is
still only one Bazel target, so the cycle in the pubspec graph never becomes
a cycle in the target graph.

Each member is declared with this rule, in the merged repository, and the
merged `dart_library` names them all in `members`:

```python
# dio/BUILD.bazel, inside the merged repository.
dart_package_member(
    name = "dio",
    package_name = "dio",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
    language_version = "2.18",
    version = "5.11.1",
)
```

```python
# The merged repository's root BUILD.bazel.
dart_library(
    name = "merged",
    members = ["//dio:dio", "//dio_web_adapter:dio_web_adapter"],
    deps = ["@dart_pub__http_parser//:http_parser", ...],
)
```

The member carries its package's facts — its sources, its name and language
version, its resolved version, its code assets and hooks — exactly as a
`dart_library` of its own would, and is checked the same way. It provides its
`DartPackageInfo` record so the merged library can collect it, and deliberately
no `DartInfo`: it is not a dependency, and listing it in `deps` is an error.
Only the merged library compiles and summarizes the members' sources, in one
module, against a package config naming every member.
"""

load("//dart:providers.bzl", "DartCodeAssetInfo", "DartPackageInfo")
load("//dart/private:common.bzl", "PACKAGE_IDENTITY_ATTRS", "codegen_identity_error", "resolve_package_identity")
load("//dart/private:dart_info.bzl", "dart_info")
load("//dart/private:dart_info_params.bzl", "dart_package_identity")
load("//dart/private:dart_library.bzl", "check_files_under_lib_root", "check_no_dart_in_data", "check_no_duplicate_srcs", "derive_lib_root", "derive_package_name", "link_hook_error")

def _dart_package_member_impl(ctx):
    identity = resolve_package_identity(ctx)
    package_name = derive_package_name(
        identity.package_name,
        ctx.label.package,
        ctx.label.name,
    )

    err = codegen_identity_error(
        ctx.label,
        ctx.attr.srcs,
        struct(
            package_name = package_name,
            language_version = identity.language_version,
        ),
    )
    if err != None:
        fail(err)

    own_resources = ctx.files.resources
    for f in own_resources:
        if f.extension == "dart":
            fail(
                ("%s: `%s` is a Dart source in `resources`. `resources` names " +
                 "the files the compiler never reads; a `.dart` file listed " +
                 "there would be staged for the analyzer and withheld from the " +
                 "compile. Move it to `srcs`.") % (ctx.label, f.short_path),
            )

    own_data = ctx.files.data
    err = check_no_dart_in_data(ctx.label, own_data)
    if err != None:
        fail(err)

    own_srcs = ctx.files.srcs
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    err = check_no_duplicate_srcs(ctx.label, own_srcs)
    if err == None:
        err = check_no_duplicate_srcs(ctx.label, own_resources, "resources")
    if err != None:
        fail(err)
    err = check_files_under_lib_root(ctx.label, lib_root, own_srcs)
    if err != None:
        fail(err)
    err = check_files_under_lib_root(ctx.label, lib_root, own_resources, "resources")
    if err != None:
        fail(err)

    err = link_hook_error(ctx.label, lib_root, ctx.file.link_hook)
    if err != None:
        fail(err)

    # The record is built by the same constructor a `dart_library` uses, with
    # no dependencies to merge — so a member states and checks exactly what a
    # library of its own would, and a field added to the record reaches both.
    # Only the record is kept: the `DartInfo` would make this target depable,
    # which is what the merged library is for.
    record = dart_info(
        label = ctx.label,
        package = dart_package_identity(
            package_name = package_name,
            lib_root = lib_root,
            language_version = identity.language_version,
            version = ctx.attr.version,
            package_files = own_data,
        ),
        deps = [],
        srcs = own_srcs,
        resources = own_resources,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = ctx.attr.has_unreplaced_hook,
        link_hook = ctx.file.link_hook,
    ).transitive_packages.to_list()[0]

    # `data` rides runfiles only, exactly as on a single-package library: the
    # merged library collects it from this target's `DefaultInfo.runfiles`
    # because a member deliberately provides no `DartInfo` of its own.
    return [
        DefaultInfo(
            files = depset(own_srcs + own_resources),
            runfiles = ctx.runfiles(files = own_srcs + own_resources + own_data),
        ),
        record,
    ]

dart_package_member = rule(
    implementation = _dart_package_member_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "The member package's Dart sources (`.dart`), under its `lib/`.",
            allow_files = [".dart"],
        ),
        "resources": attr.label_list(
            doc = "The member package's non-Dart files under its `lib/`. `.dart` files belong in `srcs`.",
            allow_files = True,
        ),
        "data": attr.label_list(
            doc = "Files this member package ships outside its `lib/` that a program reads at run time or a tool finds by walking the package root, such as `pubspec.yaml` and `LICENSE`. They ride this member's and the merged library's runfiles, never `DefaultInfo.files`, `DartInfo.transitive_resources`, or an action's inputs. `.dart` files belong in `srcs`; non-Dart files under `lib/` belong in `resources`.",
            allow_files = True,
        ),
        "code_assets": attr.label_list(
            doc = "Native code assets this member package owns (see the `dart_code_asset` rule). Each `asset_id` must be namespaced to this member's `package_name`.",
            providers = [DartCodeAssetInfo],
        ),
        "link_hook": attr.label(
            doc = "The member package's `hook/link.dart`, if it has one. Must be the file at `hook/link.dart` under the member's root.",
            allow_single_file = [".dart"],
        ),
        "has_unreplaced_hook": attr.string(
            doc = "Path of a pub build hook (`hook/build.dart`) this member ships that has no Bazel replacement, or empty.",
        ),
        "package_name": attr.string(
            doc = "The Dart package name used in `package:` imports. If omitted, defaults to the last component of the Bazel package path. Set this or `package`, not both.",
        ),
        "language_version": attr.string(
            doc = "Dart language version implied by the package's `environment.sdk` constraint, in `<major>.<minor>` form.",
        ),
        "version": attr.string(
            doc = "The package's own version, as resolved by pub. Its only use is agreement checking: two records for one package name stating different versions fail the build.",
        ),
    } | PACKAGE_IDENTITY_ATTRS,
    provides = [DartPackageInfo],
    doc = "Declares one member package of a multi-package `dart_library`. Generated by `pub.from_lock()` for each package merged over a dependency cycle; only the merged library compiles the members' sources.",
)
