"""Repository rule materialising one merged pub dependency cycle.

Pub allows packages to depend on each other, but the hub's one-`dart_library`
-per-package layout turns a mutual dependency into a cycle in the Bazel
target graph. For every strongly connected component of the lock's pubspec
dependency graph with more than one package, the extension creates one of
these repositories instead of the members' spokes. It fetches every member —
hosted tarballs and git checkouts alike — extracts each into its own
subdirectory (so each keeps its own `lib/` root), and generates one merged
`dart_library` carrying all member packages, plus an alias per member so
`@hub//:<member>` keeps working. Edges inside the cycle disappear; edges
leaving it become the merged target's `deps`. Before generating anything it
verifies the plan it was given: each member entry carries the dependency
names planning used, and the fetch fails when a member's real pubspec lists
other names or when the members are not strongly connected through their
real dependencies (the lockfile's cycle-planning facts are hints, and a
wrong one must not plan a bogus merge).
"""

load("//dart/private:download.bzl", "pinned_download")
load("//dart/pub:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "pinned_source_error")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_spoke_dep_labels", "trim_gzip_trailing_nulls")
load("//dart/pub:pub_scan.bzl", _run_pub_archive_scan = "run_pub_archive_scan")
load("//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint", "pubspec_sdk_constraint_error")
load("//dart/pub/private:build_content.bzl", _classify_pub_hooks = "classify_pub_hooks", _make_dart_package_member_build_content = "make_dart_package_member_build_content", _make_scc_merged_build_content = "make_scc_merged_build_content")
load("//dart/pub/private:language_version.bzl", _derive_language_version = "derive_language_version")
load("//dart/pub/private:pub_scc_verify.bzl", "scc_member_deps_error", "scc_members_connectivity_error", "scc_planned_deps_error")
load("//dart/pub/private:pub_symlink.bzl", _check_package_symlinks = "check_package_symlinks")

# Re-exported for rule sets outside //dart/pub that reuse the merged shape.
# Loading the private bzl directly would trip buildifier's bzl-visibility
# check, so this public file exposes it the same way `pub_lock_package.bzl`
# exposes `make_dart_library_build_content`.
make_dart_package_member_build_content = _make_dart_package_member_build_content
make_scc_merged_build_content = _make_scc_merged_build_content

def _fetch_hosted_member(ctx, member, name):
    """Downloads one hosted member tarball and extracts it into `name/`."""
    err = pinned_source_error(
        "hosted",
        name,
        member.get("version", ""),
        sha256 = member.get("sha256", ""),
        rule = "pub_lock_scc_package",
    )
    if err:
        fail(err)
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = member["url"],
        name = name,
        version = member["version"],
    )
    archive = "_" + name + ".tar.gz"

    # Same padded-tarball workaround as `pub_lock_package`: pub.dev serves
    # some archives padded with trailing NUL bytes past the gzip trailer.
    pinned_download(
        ctx,
        url = url,
        output = archive,
        sha256 = member["sha256"].strip(),
    )
    raw_archive = ctx.read(archive, watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete(archive)
        ctx.file(archive, trimmed_archive, executable = False)
    _run_pub_archive_scan(ctx, archive, name)
    ctx.extract(archive, output = name)
    ctx.delete(archive)
    _check_package_symlinks(ctx, name, name)

def _fetch_git_member(ctx, member, name):
    """Clones one git member at its resolved ref and extracts it into `name/`."""
    err = pinned_source_error(
        "git",
        name,
        member.get("version", ""),
        resolved_ref = member.get("resolved_ref", ""),
        rule = "pub_lock_scc_package",
    )
    if err:
        fail(err)
    bare_rel = "_" + name + "_bare"
    git_transport_fetch(ctx, member["url"], bare_rel, member["resolved_ref"], "pub_lock_scc_package %s" % name)
    archive_path = ctx.path("_" + name + ".tar")
    spec = member["resolved_ref"] if member["path"] == "." else member["resolved_ref"] + ":" + member["path"]
    git_materialize(ctx, bare_rel, member["resolved_ref"], archive_path, spec, "pub_lock_scc_package %s" % name)
    _run_pub_archive_scan(ctx, archive_path, name)
    ctx.extract(archive_path, output = name)
    ctx.delete(archive_path)
    ctx.delete(ctx.path(bare_rel))
    _check_package_symlinks(ctx, name, name)

def _fetch_scc_member(ctx, member, name):
    """Fetches one merged member's sources into `name/`."""
    if member.get("source", "hosted") == "git":
        _fetch_git_member(ctx, member, name)
    else:
        _fetch_hosted_member(ctx, member, name)

def _parsed_scc_member(ctx, member, name):
    """Fetches one member and parses its pubspec into a planning struct.

    Args:
      ctx: The repository rule context.
      member: The member's `members_json` entry dict.
      name: The member package name, also its subdirectory.

    Returns:
      struct(name, version, code_assets, planned, real_deps, pubspec,
      package_files): the member name, its version and code assets, its
      entry's `planned_deps` value (None when the entry carries none), its
      real sorted dependency names, its raw pubspec text ("" when the package
      ships none), and its runtime-file globs.
    """
    _fetch_scc_member(ctx, member, name)

    # The member's pubspec.yaml states its deps and SDK constraint, the
    # latter so the merged library mirrors pub's per-package
    # languageVersion behaviour.
    pubspec = ctx.read(name + "/pubspec.yaml") if ctx.path(name + "/pubspec.yaml").exists else ""
    sdk_err = pubspec_sdk_constraint_error(pubspec, name + "/pubspec.yaml")
    if sdk_err:
        fail(sdk_err)
    return struct(
        name = name,
        version = member["version"],
        code_assets = member.get("code_assets", []),
        planned = member.get("planned_deps", None),
        real_deps = sorted(parse_pubspec_deps(pubspec)),
        pubspec = pubspec,
        package_files = member.get("package_files", ["pubspec.yaml", "LICENSE*"]),
    )

def _verify_scc_plan(repo_name, parsed_members):
    """Fails when the merge plan disagrees with the fetched pubspecs.

    Runs both checks over every member — each entry's planned names, then the
    members' connectivity — so no BUILD file is written for a bad plan.

    Args:
      repo_name: The merged repository's name, for diagnostics.
      parsed_members: The `_parsed_scc_member` structs, in member order.
    """
    for parsed in parsed_members:
        err = scc_planned_deps_error(repo_name, parsed.name, parsed.planned)
        if err:
            fail(err)
    for parsed in parsed_members:
        err = scc_member_deps_error(repo_name, parsed.name, parsed.planned, parsed.real_deps)
        if err:
            fail(err)
    real_deps = {}
    for parsed in parsed_members:
        real_deps[parsed.name] = parsed.real_deps
    err = scc_members_connectivity_error(repo_name, real_deps)
    if err:
        fail(err)

def _scc_member_outside_labels(parsed, config):
    """Builds one member's dependency labels on targets outside the cycle.

    Args:
      parsed: The member's `_parsed_scc_member` struct.
      config: struct(available, own_names, hub_name, explicit_packages,
        scc_targets) describing the scope the merged repository joins.

    Returns:
      The spoke dep labels for the member's real deps that leave the cycle.
    """
    bazel_deps = sorted([
        d
        for d in parsed.real_deps
        if d in config.available and d not in config.own_names and d != parsed.name
    ])
    return pub_lock_spoke_dep_labels(
        bazel_deps,
        config.hub_name,
        config.explicit_packages,
        config.scc_targets,
    )

def _write_scc_member_build(ctx, parsed, config):
    """Writes one fetched member's BUILD file (phase three: plan verified).

    Args:
      ctx: The repository rule context.
      parsed: The member's `_parsed_scc_member` struct.
      config: struct(ignore_hooks) with the rule's hook suppressions.
    """
    name = parsed.name
    hooks = _classify_pub_hooks(
        has_build_hook = ctx.path(name + "/hook/build.dart").exists,
        has_link_hook = ctx.path(name + "/hook/link.dart").exists,
        build_hook_handled = bool(parsed.code_assets) or name in config.ignore_hooks,
    )
    ctx.file(name + "/BUILD.bazel", _make_dart_package_member_build_content(
        name = name,
        language_version = _derive_language_version(
            parse_pubspec_sdk_constraint(parsed.pubspec),
        ),
        code_assets = parsed.code_assets,
        has_unreplaced_hook = hooks.unreplaced_hook,
        version = parsed.version,
        link_hook = "hook/link.dart" if hooks.link_hook else "",
        merged_label = "//:merged",
        package_files = parsed.package_files,
    ))

def _write_scc_build_files(ctx, parsed_members, config):
    """Writes the merged BUILD file and every member's BUILD file.

    Runs only after `_verify_scc_plan` accepted the whole plan.

    Args:
      ctx: The repository rule context.
      parsed_members: The `_parsed_scc_member` structs, in member order.
      config: struct(repo_name, own_names) plus the fields
        `_scc_member_outside_labels` and `_write_scc_member_build` take.
    """
    merged_deps = {}
    for parsed in parsed_members:
        for label in _scc_member_outside_labels(parsed, config):
            merged_deps[label] = True
    for parsed in parsed_members:
        _write_scc_member_build(ctx, parsed, config)
    ctx.file("BUILD.bazel", _make_scc_merged_build_content(
        members = sorted(config.own_names.keys()),
        dep_labels = sorted(merged_deps.keys()),
        repo_name = config.repo_name,
    ))

def _pub_lock_scc_package_impl(ctx):
    members = json.decode(ctx.attr.members_json)
    config = struct(
        repo_name = ctx.attr.repo_name,
        hub_name = ctx.attr.hub_name,
        explicit_packages = ctx.attr.explicit_packages,
        scc_targets = ctx.attr.scc_targets,
        ignore_hooks = ctx.attr.ignore_hooks,
        available = {p: True for p in ctx.attr.lock_packages + ctx.attr.explicit_packages},
        own_names = {member["name"]: True for member in members},
    )

    # Phase one: fetch and parse every member. Phase two verifies the whole
    # plan before anything is generated; phase three writes every BUILD file.
    parsed_members = []
    for member in members:
        parsed_members.append(_parsed_scc_member(ctx, member, member["name"]))
    _verify_scc_plan(config.repo_name, parsed_members)
    _write_scc_build_files(ctx, parsed_members, config)

pub_lock_scc_package = repository_rule(
    implementation = _pub_lock_scc_package_impl,
    attrs = {
        "repo_name": attr.string(
            doc = "The merged repository's apparent name, for its default-target alias. " +
                  "Explicit `pub.package()` deps name the vanished spokes' repositories " +
                  "by apparent name, so the alias must match it.",
            mandatory = True,
        ),
        "members_json": attr.string(
            doc = "JSON list of member packages. Hosted members carry `{source: \"hosted\", name, version, " +
                  "sha256, url, code_assets}`; git members carry `{source: \"git\", name, version, url, " +
                  "resolved_ref, path, code_assets}`. A git member's `resolved_ref` must be a full 40-hex " +
                  "commit SHA; anything else fails the build. Every member also carries `planned_deps`, the " +
                  "sorted dependency names cycle planning used for it: the fetch fails when a member's real " +
                  "pubspec lists other names, when a member entry carries no `planned_deps` list of strings, " +
                  "or when the members are not strongly connected through their " +
                  "real dependencies. Encoded by the `pub` extension; decoded here.",
            mandatory = True,
        ),
        "hub_name": attr.string(
            doc = "Prefix for sibling spoke repo names (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All hosted package names in the lock scope (for dep filtering).",
            default = [],
        ),
        "explicit_packages": attr.string_list(
            doc = "Every name declared with `pub.package()`. A dependency on one of these " +
                  "points at that explicit repository, not a spoke.",
            default = [],
        ),
        "scc_targets": attr.string_dict(
            doc = "Package name to merged repository target, for dependencies on members of " +
                  "other merged cycles in the same scope.",
            default = {},
        ),
        "ignore_hooks": attr.string_list(
            doc = "Pub package names whose `hook/build.dart` is knowingly irrelevant to this " +
                  "build. Suppresses the unreplaced-hook error for them.",
            default = [],
        ),
    },
    doc = "Downloads every package of one merged dependency cycle into subdirectories and generates one multi-package `dart_library`.",
)
