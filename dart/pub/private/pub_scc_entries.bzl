"""Member entries for a merged pub dependency cycle.

The `pub` module extension resolves a lock, plans its cycles, and hands each
merged repository the member coordinates it needs in `members_json`. Building
those entries is pure given the resolved packages, so it lives here rather
than beside the extension's state machine: the extension file is already over
its size limit, and a new field on each entry should not make it grow.
"""

load("//dart/ext:registry.bzl", "curated_code_assets")

def scc_member_entries(members, hosted, git_pkgs, package_deps):
    """Builds the merged repository's member entries for `members_json`.

    Pure given the resolved packages: hosted members carry their tarball
    coordinates, git members their remote, resolved ref and in-repo path, so
    the merged repository fetches each member the way its spoke would. Each
    entry also carries the sorted dependency names planning used for that
    member — the same unfiltered names the facts record — so the merged
    repository verifies the plan against the real pubspecs.

    Args:
      members: Sorted member package names.
      hosted: Dict of hosted package name to
        `struct(version, sha256, url)`.
      git_pkgs: Dict of git package name to
        `struct(version, url, resolved_ref, path)`.
      package_deps: Dict of package name to the sorted dependency names
        planning used.

    Returns:
      List of structs, each with `source` (`"hosted"` or `"git"`), the
      coordinates the merged repository rule reads, `planned_deps`, and the
      member's runtime `package_files` globs.
    """
    entries = []
    for member in members:
        planned = sorted(package_deps[member])
        if member in hosted:
            pkg = hosted[member]
            entries.append(struct(
                source = "hosted",
                name = member,
                version = pkg.version,
                sha256 = pkg.sha256,
                url = pkg.url,
                code_assets = curated_code_assets(member, pkg.version),
                planned_deps = planned,
                package_files = getattr(pkg, "package_files", ["pubspec.yaml", "LICENSE*"]),
            ))
        else:
            pkg = git_pkgs[member]
            entries.append(struct(
                source = "git",
                name = member,
                version = pkg.version,
                url = pkg.url,
                resolved_ref = pkg.resolved_ref,
                path = pkg.path,
                code_assets = curated_code_assets(member, pkg.version),
                planned_deps = planned,
                package_files = getattr(pkg, "package_files", ["pubspec.yaml", "LICENSE*"]),
            ))
    return entries
