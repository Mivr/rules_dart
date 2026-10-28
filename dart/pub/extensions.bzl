"""Module extension for declaring pub.dev package dependencies."""

load("//dart/ext:registry.bzl", "curated_code_assets")
load("//dart/private:download.bzl", "pinned_download")
load("//dart/pub:pinned_sources.bzl", "git_materialize", "git_transport_fetch", "pinned_source_error")
load("//dart/pub:pub_lock_hub.bzl", "pub_lock_hub")
load("//dart/pub:pub_lock_package.bzl", "pub_lock_git_package", "pub_lock_package", "pub_lock_package_sha256_error", "trim_gzip_trailing_nulls")
load("//dart/pub:pub_lock_scc.bzl", "pub_lock_scc_package")
load("//dart/pub:pub_scan.bzl", "run_pub_archive_scans")
load("//dart/pub:yaml_parser.bzl", "lock_package_error", "parse_pubspec_deps", "parse_pubspec_lock")
load("//dart/pub/private:build_content.bzl", "PACKAGE_FILES_ATTR_DOC")
load("//dart/pub/private:parser_sources.bzl", "PARSER_SOURCE_LABELS")
load("//dart/pub/private:pub_repository.bzl", "pub_package")
load("//dart/pub/private:pub_resolution_warnings.bzl", _warn_skipped_sources = "warn_skipped_sources")
load("//dart/pub/private:pub_root_pin.bzl", "best_entry", "decl_lock_sha_conflict", "git_path_conflict", "git_ref_conflict", "git_version_error", "hosted_sha_conflict", "hosted_version_error", "select_all_explicit")
load("//dart/pub/private:pub_scanner_sdk.bzl", "scanner_runtime_label")
load("//dart/pub/private:pub_scc_entries.bzl", _scc_member_entries = "scc_member_entries")
load("//dart/pub/private:pub_scc_facts.bzl", "parser_schema", "read_scope_pubspec", "record_scope_facts", "split_scope_facts")
load("//dart/pub/private:scc.bzl", "compute_sccs", "package_dep_graph", "rewrite_vanished_spoke", "scc_repo_name")

_SPOKE_PREFIX = "dart_pub"

# Re-exported for //dart/tests, which exercises the entry shape directly.
scc_member_entries = _scc_member_entries

_package = tag_class(
    doc = "Declares one pub.dev package to download and materialize as a spoke repository, pinned by version and archive hash with its pub dependencies. A `package` tag from the root module wins over `package` tags for the same package from dependencies: a dependency's different version is dropped with a NOTE naming both versions. A root lock's git entry pins like a hosted one, and a root pin never hides a same-version sha256 conflict.",
    attrs = {
        "name": attr.string(
            doc = "The pub.dev package name (also used as the repository name).",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive.",
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
)

_from_lock = tag_class(
    doc = "Resolves a pubspec.lock file into one hub repository and its package spokes, joining the global version resolution unless isolated. A package pinned by a lock the root module reads keeps the resolved version when a dependency declares another version with `pub.package()`: the dependency's version is dropped with a NOTE naming the resolved version. A root lock's git entry pins like a hosted one, and a root pin never hides a same-version sha256 conflict.",
    attrs = {
        "name": attr.string(
            doc = "Repository name for the resolved packages. The name is global to the " +
                  "extension, not scoped to the declaring module: every `from_lock` that " +
                  "states it — in any module in the build — contributes to one hub holding " +
                  "the union of those locks, and each package is aliased once. That is what " +
                  "makes two modules that both call their hub the obvious thing work when a " +
                  "third depends on both. It also means a module can reach a package only " +
                  "another module's lock names, which resolves today and breaks the day that " +
                  "module leaves the build, so state in your own lock everything you import. " +
                  "Package versions are reconciled across the union — see " +
                  "`on_version_conflict`.",
            mandatory = True,
        ),
        "lock": attr.label(
            doc = "The pubspec.lock file to parse.",
            mandatory = True,
            allow_single_file = True,
        ),
        "ignore_hooks": attr.string_list(
            doc = "Pub package names whose `hook/build.dart` is knowingly irrelevant to this " +
                  "build (its native code is never reached). Suppresses the unreplaced-hook " +
                  "error for them. This is a declaration you make deliberately; it is never a " +
                  "default.",
            default = [],
        ),
        "on_version_conflict": attr.string(
            doc = "What to do when another lock file provides a higher version of a package. " +
                  "'error' (default) fails the build. 'upgrade' accepts the higher version. " +
                  "Ignored for isolated hubs, which never join version resolution.",
            default = "error",
            values = ["error", "upgrade"],
        ),
        "isolated": attr.bool(
            doc = "When True, this hub is isolated: its spokes are namespaced by the hub " +
                  "name (`<hub>__<pkg>`), it does not join the global registry or " +
                  "`on_version_conflict` resolution, and it pins the versions in its own " +
                  "lock. Use for standalone tools that need a different version of a " +
                  "package than the rest of the build. Defaults to False.",
            default = False,
        ),
        "package_files": attr.string_list(
            doc = "Applies to every package this lock materializes, including merged cycle " +
                  "members. " + PACKAGE_FILES_ATTR_DOC,
            default = ["pubspec.yaml", "LICENSE*"],
        ),
    },
)

def _parser_schema(ctx):
    """Builds this evaluation's fact-key schema from the parser sources' bytes.

    Reads the parser files with `watch = "no"`: no new recorded input is
    needed, because the extension's own `bzlTransitiveDigest` already
    re-evaluates it when they change.

    Args:
      ctx: The module extension context.

    Returns:
      The schema prefix every fact key of this evaluation carries.
    """
    return parser_schema([ctx.read(label, watch = "no") for label in PARSER_SOURCE_LABELS])

def _scope_pubspec_deps(ctx, scope_dir, hosted, git_pkgs):
    """Downloads each in-scope package and returns its sorted dependency names.

    The extension needs every package's `dependencies:` to find dependency
    cycles before any repository is generated, so it downloads the same
    tarballs the hosted spokes will (verified by the same sha256) and clones
    the same git revisions the git spokes will, reading the one file it needs
    from each. The padded-tarball workaround is the spokes'
    (`trim_gzip_trailing_nulls`): some pub.dev archives end past the gzip
    trailer, which Bazel's extractor rejects. Each pubspec is parsed once;
    the one result is what facts record and what planning consumes.

    Every archive is scanned before the first extraction: all packages
    download first, one snapshot invocation scans the batch in hosted
    (sorted) then git (sorted) order — the order the old per-package scans
    refused in — and only then is anything extracted. Every spoke still
    scans its own downloaded archive before extracting it: the planning
    verdict never travels to the spokes, so no lockfile entry can weaken
    their scan.

    Args:
      ctx: The module extension context.
      scope_dir: Scratch directory for this scope's downloads, unique per
        scope so shared and isolated scopes never collide.
      hosted: Dict of hosted package name to `struct(version, sha256, url)`.
      git_pkgs: Dict of git package name to
        `struct(version, url, resolved_ref, path)`.

    Returns:
      Dict of package name to its sorted `dependencies:` names ([] when the
      package ships no pubspec).
    """
    deps = {}
    ctx.file(scope_dir + "/.scc_scope", "pub dependency-cycle scope scratch")
    pending = []
    for name in sorted(hosted.keys()):
        pkg = hosted[name]
        err = pinned_source_error(
            "hosted",
            name,
            pkg.version,
            sha256 = pkg.sha256,
            rule = "pub.from_lock",
        )
        if err:
            fail(err)
        url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
            base = pkg.url,
            name = name,
            version = pkg.version,
        )
        archive = "{dir}/{name}.tar.gz".format(dir = scope_dir, name = name)
        out = "{dir}/{name}".format(dir = scope_dir, name = name)
        pinned_download(ctx, url = url, output = archive, sha256 = pkg.sha256)
        raw = ctx.read(archive)
        trimmed = trim_gzip_trailing_nulls(raw)
        if trimmed != raw:
            ctx.file(archive, trimmed, executable = False)
        pending.append(struct(archive = archive, name = name, out = out))
    for name in sorted(git_pkgs.keys()):
        pkg = git_pkgs[name]
        err = pinned_source_error(
            "git",
            name,
            pkg.version,
            resolved_ref = pkg.resolved_ref,
            rule = "pub.from_lock",
        )
        if err:
            fail(err)

        # Absolute paths: `--git-dir` and `-o` take absolute paths, so no
        # command depends on the working directory.
        bare_rel = "{dir}/{name}_bare".format(dir = scope_dir, name = name)
        out = "{dir}/{name}".format(dir = scope_dir, name = name)
        git_transport_fetch(ctx, pkg.url, bare_rel, pkg.resolved_ref, 'pub.from_lock "%s"' % name)
        archive = str(ctx.path("{dir}/{name}.tar".format(dir = scope_dir, name = name)))
        spec = pkg.resolved_ref if pkg.path == "." else pkg.resolved_ref + ":" + pkg.path
        git_materialize(ctx, bare_rel, pkg.resolved_ref, archive, spec, 'pub.from_lock "%s"' % name)
        pending.append(struct(archive = archive, name = name, out = out))
    if pending:
        # Scratch is check-only, but the check still runs before extraction:
        # a hostile tarball fails planning here, not after its links land.
        run_pub_archive_scans(ctx, [struct(archive = p.archive, name = p.name) for p in pending])
    for p in pending:
        ctx.extract(p.archive, output = p.out)
        deps[p.name] = sorted(parse_pubspec_deps(read_scope_pubspec(ctx, p.name, p.out)))
    return deps

def touch_scanner_runtime_label(ctx):
    """Resolves the scanner runtime label so cold and warm lockfiles stay byte-identical.

    `run_pub_archive_scans` resolves `scanner_runtime_label(ctx.os)` through
    this module's repo mapping, which the lockfile records as a
    `REPO_MAPPING` input — but only on evaluations that actually scan. A warm
    evaluation whose facts hit for every package scans nothing, so without
    this touch its recorded inputs miss that line. Resolving the same label
    here, for every scope that holds hosted or git packages whether or not
    anything misses the facts, records the identical input on both paths.
    Label construction only: no `ctx.path` and no download, so a warm
    evaluation still fetches nothing. The scanner snapshot label needs no
    touch: it is a module-level `Label` in `pub_scan.bzl`, resolved at load
    on every evaluation already.

    Args:
      ctx: The module extension context.

    Returns:
      The scanner runtime label, so tests can pin that it names the same
      label the scan resolves.
    """
    return scanner_runtime_label(ctx.os)

def _scope_deps_with_facts(ctx, scope_dir, hosted, git_pkgs, recorded):
    """Resolves one scope's dependency names, reusing lockfile facts for unchanged packages. Returns deps."""
    if hosted or git_pkgs:
        touch_scanner_runtime_label(ctx)
    schema = _parser_schema(ctx)
    split = split_scope_facts(ctx.facts, hosted, git_pkgs, schema)
    miss_deps = {}
    if split.hosted_miss or split.git_miss:
        miss_deps = _scope_pubspec_deps(ctx, scope_dir, split.hosted_miss, split.git_miss)
    record_scope_facts(recorded, split, miss_deps)
    deps = dict(split.deps)
    for name in miss_deps.keys():
        deps[name] = miss_deps[name]
    return deps

def plan_scope_sccs(scope_names, explicit_deps, hub_names, spoke_prefix, package_deps):
    """Plans the merges of one lock scope from its packages' dependency names.

    Args:
      scope_names: Every package name in scope (hosted plus explicit).
      explicit_deps: Dict of explicit package name to user-declared deps.
      hub_names: All hub repository names in scope.
      spoke_prefix: The scope's spoke repo name prefix.
      package_deps: Dict of package name to its sorted dependency names — the
        names planning consumes, from the lockfile facts or one pubspec parse
        each. Each name is one edge: names are never rendered back into
        pubspec text, so quotes, newlines or colons in a name cannot split it
        into several.

    Returns:
      `struct(members, merged, package_deps)`: `members` maps every merged
      package name to its merged repository name; `merged` maps each merged
      repository name to its sorted member names; `package_deps` carries the
      sorted names planning used, so merged member entries record what was
      planned for later verification against the real pubspecs. Cycles
      touching an explicit `pub.package()` are left alone — that repository
      is user-managed, so nothing can be merged into it, and the target cycle
      fails as it does today.
    """
    graph = package_dep_graph(
        package_deps,
        explicit_deps,
        scope_names,
        hub_names,
        [spoke_prefix],
    )
    members = {}
    merged = {}
    for component in compute_sccs(graph):
        if len(component) < 2:
            continue
        if any([m in explicit_deps for m in component]):
            continue
        repo = scc_repo_name(spoke_prefix, component)
        merged[repo] = component
        for member in component:
            members[member] = repo
    return struct(
        members = members,
        merged = merged,
        package_deps = {name: sorted(package_deps[name]) for name in package_deps.keys()},
    )

def _resolve_state():
    """Returns the mutable resolution state for lock collection."""

    # registry[pkg_name] = {url, entries: [{version, sha256, hub_name, lock_label, on_version_conflict}]}
    # git_registry mirrors it for git-sourced packages, pinned by commit SHA.
    # hub_packages maps each hub to its package set (a set, not a list: a hub
    # name is shared by every `from_lock` stating it, so it holds their union).
    return {
        "registry": {},
        "git_registry": {},
        "hub_packages": {},
        "warnings": [],
        "isolated_hubs": {},
        "isolated_hub_packages": {},
        "isolated_git_packages": {},
    }

def _resolve_hub_scope(state, lock_tag):
    """Registers a lock tag's hub scope. Returns (hub_name, isolated, error)."""
    hub_name = lock_tag.name
    isolated = getattr(lock_tag, "isolated", False)
    if hub_name in state["isolated_hubs"] and state["isolated_hubs"][hub_name] != isolated:
        return hub_name, isolated, "Hub \"%s\" is declared both isolated and non-isolated." % hub_name
    state["isolated_hubs"][hub_name] = isolated
    state["hub_packages"].setdefault(hub_name, {})
    if isolated:
        state["isolated_hub_packages"].setdefault(hub_name, {})
    return hub_name, isolated, None

def _lock_entry_error(name, info, lock_tag):
    """Returns the lock-entry error string, or None when the entry is valid."""
    err = lock_package_error(name, info, lock_tag.lock)
    if not err:
        return None
    if info.get("source") == "hosted":
        sha_err = pub_lock_package_sha256_error(
            name,
            info.get("version", ""),
            info.get("description", {}).get("sha256", ""),
        )
        return "%s (%s)" % (err, sha_err)
    return err

def _register_git_package(state, name, info, lock_tag, hub_name, isolated):
    """Registers one git-sourced lock entry. Returns the error string, or None."""

    # Git packages are fetched at their resolved-ref commit, like
    # hosted packages, and exposed in the hub the same way.
    state["hub_packages"][hub_name][name] = True

    desc = info.get("description", {})
    url = desc.get("url", "")
    version = info.get("version", "")
    resolved_ref = desc.get("resolved-ref", "").strip()
    path = desc.get("path", ".")
    if path == None or str(path).strip() == "":
        path = "."
    package_files = getattr(lock_tag, "package_files", ["pubspec.yaml", "LICENSE*"])

    if not url:
        return 'pub package "%s" %s in %s has no url for its git source.' % (name, version, lock_tag.lock)

    if isolated:
        # Isolated hubs pin their own versions: the spoke is
        # namespaced by the hub and never joins the global
        # registry or `on_version_conflict` resolution.
        state["isolated_git_packages"].setdefault(hub_name, {})[name] = struct(
            version = version,
            url = url,
            resolved_ref = resolved_ref,
            path = path,
            package_files = package_files,
        )
        return None

    entry = struct(
        version = version,
        resolved_ref = resolved_ref,
        path = path,
        hub_name = hub_name,
        lock_label = str(lock_tag.lock),
        on_version_conflict = lock_tag.on_version_conflict,
        package_files = package_files,
    )

    git_registry = state["git_registry"]
    if name not in git_registry:
        git_registry[name] = struct(url = url, entries = [entry])
        return None
    existing = git_registry[name]
    if existing.url != url:
        return (
            "Package \"%s\" has conflicting git URLs:\n" % name +
            "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
            "  - %s (from \"%s\")" % (url, hub_name)
        )
    git_registry[name] = struct(url = existing.url, entries = existing.entries + [entry])
    return None

def _register_hosted_package(state, explicit, name, info, lock_tag, hub_name, isolated):
    """Registers one hosted lock entry. Returns the error string, or None."""
    state["hub_packages"][hub_name][name] = True

    desc = info.get("description", {})
    url = desc.get("url", "https://pub.dev")
    version = info.get("version", "")
    sha256 = desc["sha256"].strip()
    package_files = getattr(lock_tag, "package_files", ["pubspec.yaml", "LICENSE*"])

    if isolated:
        state["isolated_hub_packages"][hub_name][name] = struct(
            version = version,
            sha256 = sha256,
            url = url,
            package_files = package_files,
        )
        return None

    if name in explicit:
        exp = explicit[name]
        if exp.version == version and exp.sha256 != sha256:
            return decl_lock_sha_conflict(name, version, exp.sha256, hub_name, str(lock_tag.lock), sha256)

    entry = struct(
        version = version,
        sha256 = sha256,
        hub_name = hub_name,
        lock_label = str(lock_tag.lock),
        on_version_conflict = lock_tag.on_version_conflict,
        package_files = package_files,
    )

    registry = state["registry"]
    if name not in registry:
        registry[name] = struct(url = url, entries = [entry])
        return None
    existing = registry[name]
    if existing.url != url:
        return (
            "Package \"%s\" has conflicting registry URLs:\n" % name +
            "  - %s (from \"%s\")\n" % (existing.url, existing.entries[0].hub_name) +
            "  - %s (from \"%s\")\n" % (url, hub_name)
        )
    registry[name] = struct(url = existing.url, entries = existing.entries + [entry])
    return None

def _register_lock_package(state, explicit, name, info, lock_tag, hub_name, isolated, skipped_by_source):
    """Registers one lock entry by source. Returns (error, error_shape)."""
    err = _lock_entry_error(name, info, lock_tag)
    if err:
        return err, "lock"
    source = info.get("source", "unknown")
    if source == "git":
        return _register_git_package(state, name, info, lock_tag, hub_name, isolated), "git"
    if source != "hosted":
        skipped_by_source.setdefault(source, []).append(name)
        return None, "lock"
    return _register_hosted_package(state, explicit, name, info, lock_tag, hub_name, isolated), "lock"

def _resolve_lock_tag(state, explicit, lock_tag):
    """Collects one lock file's entries into the state. Returns (error, error_shape)."""
    hub_name, isolated, err = _resolve_hub_scope(state, lock_tag)
    if err:
        return err, "hub"

    skipped_by_source = {}
    for name, info in lock_tag.packages.items():
        err, shape = _register_lock_package(state, explicit, name, info, lock_tag, hub_name, isolated, skipped_by_source)
        if err:
            return err, shape

    _warn_skipped_sources(state, lock_tag, hub_name, skipped_by_source)
    return None, ""

def _resolve_hosted_package(name, pkg, explicit, git_registry, warnings):
    """Resolves one hosted package. Returns (resolved_struct_or_None, skip_reason, error)."""
    err = hosted_sha_conflict(name, pkg.entries)
    if err:
        return None, "", err
    if name in explicit:
        return None, "explicit", None
    if name in git_registry:
        # A package listed as both hosted and git materialises once, from
        # its git checkout: generating both a hosted spoke and a git spoke
        # would name two repositories dart_pub__<name>, and a merged cycle
        # would otherwise fetch the hosted tarball and drop the git
        # checkout silently. A single pubspec.lock cannot list both (its
        # package names are unique), so this only fires across the union
        # of several locks.
        git_pkg = git_registry[name]
        lines = ["Package \"%s\" is listed as both a hosted package and a git package; using the git checkout and ignoring the hosted entries:" % name]
        for e in pkg.entries:
            lines.append("  - %s (hosted, from \"%s\", %s)" % (e.version, e.hub_name, e.lock_label))
        for e in git_pkg.entries:
            lines.append("  - %s (git, from \"%s\", %s)" % (e.version, e.hub_name, e.lock_label))
        warnings.append("\n".join(lines))
        return None, "git", None
    if len(pkg.entries) == 1:
        e = pkg.entries[0]
        return struct(version = e.version, sha256 = e.sha256, url = pkg.url, package_files = e.package_files), "", None
    best = best_entry(pkg.entries)
    for e in pkg.entries:
        if e.version != best.version and e.on_version_conflict == "error":
            return None, "", hosted_version_error(name, pkg.entries, best)
    return struct(
        version = best.version,
        sha256 = best.sha256,
        url = pkg.url,
        package_files = best.package_files,
    ), "", None

def _resolve_hosted(state, explicit):
    """Resolves every hosted package to one version. Returns (resolved, error)."""
    resolved = {}
    git_registry = state["git_registry"]
    for name, pkg in state["registry"].items():
        entry, _, err = _resolve_hosted_package(name, pkg, explicit, git_registry, state["warnings"])
        if err:
            return {}, err
        if entry != None:
            resolved[name] = entry
    return resolved, None

def _resolve_git_versions(state):
    """Resolves every git package to one version. Returns (resolved_git, error)."""
    resolved_git = {}
    for name, pkg in state["git_registry"].items():
        err = git_ref_conflict(name, pkg.entries)
        if err:
            return {}, err
        err = git_path_conflict(name, pkg.entries)
        if err:
            return {}, err
        if len(pkg.entries) == 1:
            e = pkg.entries[0]
            resolved_git[name] = struct(
                version = e.version,
                url = pkg.url,
                resolved_ref = e.resolved_ref,
                path = e.path,
                package_files = e.package_files,
            )
            continue
        best = best_entry(pkg.entries)
        for e in pkg.entries:
            if e.version != best.version and e.on_version_conflict == "error":
                return {}, git_version_error(name, pkg.entries)
        resolved_git[name] = struct(
            version = best.version,
            url = pkg.url,
            resolved_ref = best.resolved_ref,
            path = best.path,
            package_files = best.package_files,
        )
    return resolved_git, None

def _resolve_isolated_overlap(state):
    """Drops hosted entries shadowed by a git checkout in an isolated hub."""

    # A package listed as both hosted and git in one isolated hub
    # materialises once, from its git checkout, like the shared scope above.
    for hub_name, git_pkgs in state["isolated_git_packages"].items():
        hosted = state["isolated_hub_packages"].get(hub_name, {})
        for name in sorted(git_pkgs.keys()):
            if name in hosted:
                state["warnings"].append(
                    "\n".join([
                        "Package \"%s\" in isolated hub \"%s\" is listed as both a hosted package and a git package; using the git checkout and ignoring the hosted entry:" % (name, hub_name),
                        "  - %s (hosted)" % hosted[name].version,
                        "  - %s (git)" % git_pkgs[name].version,
                    ]),
                )
                hosted.pop(name)

def _resolve_error_sha(error):
    """The error struct for `pub.package()` pin errors."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_conflict(error):
    """The error struct for conflicting `pub.package()` declarations."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        isolated_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_hub(error):
    """The error struct for isolated/non-isolated hub conflicts."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        hub_packages = {},
        isolated_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_lock(error):
    """The error struct for lock-collection and hosted-resolution failures."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        isolated_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def _resolve_error_git(error):
    """The error struct for git-registration and git-resolution failures."""
    return struct(
        error = error,
        explicit = {},
        resolved = {},
        resolved_git = {},
        hub_packages = {},
        isolated_packages = {},
        isolated_git_packages = {},
        aliases = {},
        notes = [],
        warnings = [],
    )

def resolve_pub_packages(package_tags, lock_tags):
    """Validates and resolves `pub.package` and `pub.from_lock` declarations.

    Every `pub.package` and hosted `pub.from_lock` entry must carry a
    64-lowercase-hex-digit `sha256` after trimming, even when later superseded
    by version resolution or an explicit `pub.package()`. Conflicting `sha256`
    values for the same package version across lock files or between
    `pub.package()` and a lock file are rejected. A package listed as both a
    hosted package and a git package resolves to its git checkout: the hosted
    entries are ignored with a warning, so the package materialises exactly
    once however the dependency cycles fall.

    The root module wins over dependencies: its `pub.package()` pin, or the
    version its non-isolated `pub.from_lock` locks settle on, resolves when a
    non-root `pub.package()` declares another version, with an informational
    NOTE naming the resolved version. A root lock's git entry pins like a
    hosted one. A non-root declaration at the resolved version
    with a different sha256 is an integrity conflict and fails.

    Args:
        package_tags: List of structs with `(name, version, sha256, deps)`
            and optionally `(is_root, module)`. Tags without `is_root`
            count as root.
        lock_tags: List of structs with `(name, lock, packages, on_version_conflict, isolated)`
            and optionally `(is_root, module)`.

    Returns:
        `struct(error, explicit, resolved, resolved_git, hub_packages, isolated_packages, isolated_git_packages, aliases, notes, warnings)`
        where `error` is an error string when any declaration is unpinned,
        malformed, or conflicting, or `None` when resolution succeeds.
        `isolated_packages` maps each isolated hub name to
        `{pkg_name: struct(version, sha256, url)}` and `isolated_git_packages`
        maps each isolated hub name to
        `{pkg_name: struct(version, url, resolved_ref, path)}`. `aliases`
        maps package name to `(version, sha256, source)` for names a root
        lock pin resolves while declarations exist: the package-named
        repository is generated as an alias to the lock spoke. `notes` holds
        one NOTE per package whose root pin overrode a different version.
    """
    explicit, aliases, notes, err, err_shape = select_all_explicit(package_tags, lock_tags)
    if err:
        if err_shape == "sha":
            return _resolve_error_sha(err)
        return _resolve_error_conflict(err)

    state = _resolve_state()
    for lock_tag in lock_tags:
        err, err_shape = _resolve_lock_tag(state, explicit, lock_tag)
        if err:
            if err_shape == "hub":
                return _resolve_error_hub(err)
            if err_shape == "git":
                return _resolve_error_git(err)
            return _resolve_error_lock(err)

    resolved, err = _resolve_hosted(state, explicit)
    if err:
        return _resolve_error_lock(err)

    resolved_git, err = _resolve_git_versions(state)
    if err:
        return _resolve_error_git(err)

    _resolve_isolated_overlap(state)

    return struct(
        error = None,
        explicit = explicit,
        resolved = resolved,
        resolved_git = resolved_git,
        hub_packages = state["hub_packages"],
        isolated_packages = state["isolated_hub_packages"],
        isolated_git_packages = state["isolated_git_packages"],
        aliases = aliases,
        notes = notes,
        warnings = state["warnings"],
    )

def _pub_collect_tags(ctx):
    """Collects package/lock tags across modules. Returns (package_tags, lock_tags, ignore_hooks, root_repos)."""

    # Packages the user has declared hook-irrelevant, unioned across every
    # from_lock call — a package is one repo regardless of how many locks
    # mention it, so the flag cannot be per-lock.
    ignore_hooks = {}

    # Repos the root module names, mapped to whether every naming is a
    # `dev_dependency = True` usage: Bazel checks the root's `use_repo` calls
    # against that split, and fails a dev-only root that reports non-dev repos.
    root_repos = {}

    package_tags = []
    lock_tags = []
    for mod in ctx.modules:
        module_name = getattr(mod, "name", "")
        for pkg in mod.tags.package:
            package_tags.append(struct(
                name = pkg.name,
                version = pkg.version,
                sha256 = pkg.sha256,
                deps = pkg.deps,
                package_files = pkg.package_files,
                is_root = mod.is_root,
                module = module_name,
            ))
            if mod.is_root:
                root_repos[pkg.name] = root_repos.get(pkg.name, True) and ctx.is_dev_dependency(pkg)

        for lock_tag in mod.tags.from_lock:
            for pkg_name in lock_tag.ignore_hooks:
                ignore_hooks[pkg_name] = True
            if mod.is_root:
                root_repos[lock_tag.name] = root_repos.get(lock_tag.name, True) and ctx.is_dev_dependency(lock_tag)
            lock_content = ctx.read(lock_tag.lock)
            lock_tags.append(struct(
                name = lock_tag.name,
                lock = lock_tag.lock,
                packages = parse_pubspec_lock(lock_content, str(lock_tag.lock)),
                on_version_conflict = lock_tag.on_version_conflict,
                isolated = lock_tag.isolated,
                package_files = lock_tag.package_files,
                is_root = mod.is_root,
                module = module_name,
            ))
    return package_tags, lock_tags, ignore_hooks, root_repos

def _pub_scope_deps(ctx, scope_dir, scope_names, explicit_package_names, explicit_deps, hosted, git_pkgs, recorded):
    """Resolves one scope's dependency names when cycle planning needs them, reusing lockfile facts for unchanged packages. Returns deps."""
    deps = {}
    if len(scope_names) > len(explicit_package_names) + 1 or (scope_names != explicit_package_names and any([explicit_deps[name] for name in explicit_deps])):
        deps = _scope_deps_with_facts(ctx, scope_dir, hosted, git_pkgs, recorded)
    return deps

def _pub_plan_shared_sccs(ctx, resolution, explicit_package_names, recorded):
    """Plans the shared scope's merges. Returns (shared_sccs, vanished_spokes)."""
    resolved = resolution.resolved
    resolved_git = resolution.resolved_git
    hub_packages = resolution.hub_packages
    isolated_packages = resolution.isolated_packages
    isolated_git_packages = resolution.isolated_git_packages
    explicit_deps = {name: pkg.deps for name, pkg in resolution.explicit.items()}
    shared_hubs = sorted([
        hub_name
        for hub_name in hub_packages.keys()
        if hub_name not in isolated_packages and hub_name not in isolated_git_packages
    ])
    shared_names = sorted(set(resolved.keys()) | set(resolved_git.keys())) + explicit_package_names
    shared_deps = _pub_scope_deps(ctx, "_scc_shared", shared_names, explicit_package_names, explicit_deps, resolved, resolved_git, recorded)
    shared_sccs = plan_scope_sccs(
        shared_names,
        explicit_deps,
        shared_hubs,
        _SPOKE_PREFIX,
        shared_deps,
    )

    # Merged-away spokes vanish, so an explicit `pub.package()` naming one
    # must name its merged repository instead (a hub alias would keep
    # working, but a spoke label would not resolve).
    vanished_spokes = {}
    for member, repo in shared_sccs.members.items():
        vanished_spokes[_SPOKE_PREFIX + "__" + member] = repo
    return shared_sccs, vanished_spokes

def _pub_plan_isolated_sccs(ctx, hub_name, resolution, explicit_package_names, vanished_spokes, recorded):
    """Plans one isolated hub's merges. Returns the hub's sccs struct."""
    isolated_packages = resolution.isolated_packages
    isolated_git_packages = resolution.isolated_git_packages
    explicit_deps = {name: pkg.deps for name, pkg in resolution.explicit.items()}
    hosted = isolated_packages.get(hub_name, {})
    git_pkgs = isolated_git_packages.get(hub_name, {})
    hub_names = [hub_name]
    scope_names = sorted(set(hosted.keys()) | set(git_pkgs.keys())) + explicit_package_names
    deps = _pub_scope_deps(ctx, "_scc_" + hub_name, scope_names, explicit_package_names, explicit_deps, hosted, git_pkgs, recorded)
    sccs = plan_scope_sccs(
        scope_names,
        explicit_deps,
        hub_names,
        hub_name,
        deps,
    )
    for member, repo in sccs.members.items():
        vanished_spokes[hub_name + "__" + member] = repo
    return sccs

def _pub_emit_explicit(explicit, vanished_spokes):
    """Creates the explicit `pub.package()` repositories."""
    for name, pkg in explicit.items():
        pub_package(
            name = name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            deps = [rewrite_vanished_spoke(dep, vanished_spokes) for dep in pkg.deps],
            package_files = pkg.package_files,
        )

def _pub_emit_aliased(aliases, vanished_spokes):
    """Creates one alias repository per lock-pinned `pub.package()` name.

    A dependency may import the package by its `pub.package()` name even
    when a root lock pin resolves it, so the name must exist as a
    repository. The lock spoke stays the single materialization: the alias
    names its spoke, or the merged repository holding the whole cycle when
    the spoke merged away.
    """
    for name in sorted(aliases.keys()):
        spoke = _SPOKE_PREFIX + "__" + name
        scc_targets = {}
        if spoke in vanished_spokes:
            repo = vanished_spokes[spoke]
            scc_targets = {name: "@{repo}//:{member}".format(repo = repo, member = name)}
        pub_lock_hub(
            name = name,
            hub_name = _SPOKE_PREFIX,
            spoke_prefix = _SPOKE_PREFIX,
            packages = [name],
            explicit_packages = [],
            scc_targets = scc_targets,
        )

def _pub_emit_shared_spokes(resolved, shared_sccs, all_package_names, explicit_package_names, ignore_hooks, shared_scc_targets):
    """Creates shared hosted spoke repos. Cycle members get no spoke of their own: the merged repository holds the whole cycle."""
    for name, pkg in resolved.items():
        if name in shared_sccs.members:
            continue
        err = pub_lock_package_sha256_error(name, pkg.version, pkg.sha256)
        if err:
            fail(err)
        pub_lock_package(
            name = _SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            # A spoke whose pubspec depends on an explicit package depends on
            # that package's repo, which is what every hub aliases it to.
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
            scc_targets = shared_scc_targets,
            planned_deps = shared_sccs.package_deps.get(name, []),
            plan_covers_package = name in shared_sccs.package_deps,
            package_files = pkg.package_files,
        )

def _pub_emit_shared_merged(shared_sccs, resolved, resolved_git, all_package_names, explicit_package_names, shared_scc_targets, ignore_hooks):
    """Creates one merged repository per shared dependency cycle."""
    for repo, members in shared_sccs.merged.items():
        entries = scc_member_entries(members, resolved, resolved_git, shared_sccs.package_deps)
        pub_lock_scc_package(
            name = repo,
            repo_name = repo,
            members_json = json.encode(entries),
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            explicit_packages = explicit_package_names,
            scc_targets = shared_scc_targets,
            ignore_hooks = sorted(ignore_hooks.keys()),
        )

def _pub_emit_shared_git(resolved_git, shared_sccs, all_package_names, explicit_package_names, ignore_hooks, shared_scc_targets):
    """Creates shared git spoke repos."""
    for name, pkg in resolved_git.items():
        if name in shared_sccs.members:
            continue
        pub_lock_git_package(
            name = _SPOKE_PREFIX + "__" + name,
            package_name = name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            hub_name = _SPOKE_PREFIX,
            lock_packages = all_package_names,
            explicit_packages = explicit_package_names,
            code_assets = curated_code_assets(name, pkg.version),
            ignore_hook = name in ignore_hooks,
            scc_targets = shared_scc_targets,
            planned_deps = shared_sccs.package_deps.get(name, []),
            plan_covers_package = name in shared_sccs.package_deps,
            package_files = pkg.package_files,
        )

def _pub_emit_isolated_spokes(hub_name, hosted, hub_sccs, package_names, hub_explicit, hub_scc_targets, ignore_hooks):
    """Creates one isolated hub's hosted spoke repos."""
    for pkg_name, pkg in hosted.items():
        if pkg_name in hub_sccs.members:
            continue
        err = pub_lock_package_sha256_error(pkg_name, pkg.version, pkg.sha256)
        if err:
            fail(err)
        pub_lock_package(
            name = hub_name + "__" + pkg_name,
            package_name = pkg_name,
            version = pkg.version,
            sha256 = pkg.sha256,
            base_url = pkg.url,
            hub_name = hub_name,
            lock_packages = package_names,
            explicit_packages = hub_explicit,
            code_assets = curated_code_assets(pkg_name, pkg.version),
            ignore_hook = pkg_name in ignore_hooks,
            scc_targets = hub_scc_targets,
            planned_deps = hub_sccs.package_deps.get(pkg_name, []),
            plan_covers_package = pkg_name in hub_sccs.package_deps,
            package_files = pkg.package_files,
        )

def _pub_emit_isolated_merged(hub_name, hub_sccs, hosted, git_pkgs, package_names, hub_explicit, hub_scc_targets, ignore_hooks):
    """Creates one merged repository per isolated dependency cycle."""
    for repo, members in hub_sccs.merged.items():
        entries = scc_member_entries(members, hosted, git_pkgs, hub_sccs.package_deps)
        pub_lock_scc_package(
            name = repo,
            repo_name = repo,
            members_json = json.encode(entries),
            hub_name = hub_name,
            lock_packages = package_names,
            explicit_packages = hub_explicit,
            scc_targets = hub_scc_targets,
            ignore_hooks = sorted(ignore_hooks.keys()),
        )

def _pub_emit_isolated_git(hub_name, git_pkgs, hub_sccs, package_names, hub_explicit, hub_scc_targets, ignore_hooks):
    """Creates one isolated hub's git spoke repos."""
    for pkg_name, pkg in git_pkgs.items():
        if pkg_name in hub_sccs.members:
            continue
        pub_lock_git_package(
            name = hub_name + "__" + pkg_name,
            package_name = pkg_name,
            version = pkg.version,
            url = pkg.url,
            resolved_ref = pkg.resolved_ref,
            path = pkg.path,
            hub_name = hub_name,
            lock_packages = package_names,
            explicit_packages = hub_explicit,
            code_assets = curated_code_assets(pkg_name, pkg.version),
            ignore_hook = pkg_name in ignore_hooks,
            scc_targets = hub_scc_targets,
            planned_deps = hub_sccs.package_deps.get(pkg_name, []),
            plan_covers_package = pkg_name in hub_sccs.package_deps,
            package_files = pkg.package_files,
        )

def _pub_emit_isolated_hub(hub_name, isolated_packages, isolated_git_packages, isolated_sccs, explicit_package_names, ignore_hooks):
    """Creates one isolated hub's spokes and merged repositories."""

    # Create isolated spoke repos (namespaced by hub, outside the global
    # registry). Hosted and git packages in one hub share its package set so
    # cross-source deps within the hub resolve to sibling spokes.
    hosted = isolated_packages.get(hub_name, {})
    git_pkgs = isolated_git_packages.get(hub_name, {})
    package_names = sorted(set(hosted.keys()) | set(git_pkgs.keys()))
    hub_explicit = [n for n in explicit_package_names if n not in hosted and n not in git_pkgs]
    hub_scc_targets = {
        member: "@{repo}//:{member}".format(repo = repo, member = member)
        for member, repo in isolated_sccs[hub_name].members.items()
    }
    _pub_emit_isolated_spokes(hub_name, hosted, isolated_sccs[hub_name], package_names, hub_explicit, hub_scc_targets, ignore_hooks)
    _pub_emit_isolated_merged(hub_name, isolated_sccs[hub_name], hosted, git_pkgs, package_names, hub_explicit, hub_scc_targets, ignore_hooks)
    _pub_emit_isolated_git(hub_name, git_pkgs, isolated_sccs[hub_name], package_names, hub_explicit, hub_scc_targets, ignore_hooks)

def _pub_emit_hubs(hub_packages, isolated_hub_names, isolated_sccs, shared_sccs, explicit):
    """Creates the per-from_lock hub repos."""
    for hub_name, packages in hub_packages.items():
        package_names = sorted(packages)
        isolated = hub_name in isolated_hub_names
        if isolated:
            spoke_prefix = hub_name
            hub_explicit = []
            hub_scc_targets = {
                member: "@{repo}//:{member}".format(repo = repo, member = member)
                for member, repo in isolated_sccs[hub_name].members.items()
                if member in packages
            }
        else:
            spoke_prefix = _SPOKE_PREFIX
            hub_explicit = [n for n in package_names if n in explicit]
            hub_scc_targets = {
                member: "@{repo}//:{member}".format(repo = repo, member = member)
                for member, repo in shared_sccs.members.items()
                if member in packages
            }
        pub_lock_hub(
            name = hub_name,
            hub_name = hub_name,
            spoke_prefix = spoke_prefix,
            packages = package_names,
            explicit_packages = hub_explicit,
            scc_targets = hub_scc_targets,
        )

def _pub_extension_metadata(ctx, root_repos, recorded):
    """Returns this evaluation's metadata: the root's direct deps plus the cycle-planning facts for the lockfile."""
    return ctx.extension_metadata(
        root_module_direct_deps = [name for name, dev in root_repos.items() if not dev],
        root_module_direct_dev_deps = [name for name, dev in root_repos.items() if dev],
        facts = recorded,
    )

def _pub_impl(ctx):
    package_tags, lock_tags, ignore_hooks, root_repos = _pub_collect_tags(ctx)

    resolution = resolve_pub_packages(package_tags, lock_tags)
    if resolution.error:
        fail(resolution.error)

    for note in resolution.notes:
        # buildifier: disable=print
        print("NOTE: " + note)

    for warning in resolution.warnings:
        # buildifier: disable=print
        print(warning)

    explicit = resolution.explicit
    aliases = getattr(resolution, "aliases", {})
    resolved = resolution.resolved
    resolved_git = resolution.resolved_git
    hub_packages = resolution.hub_packages
    isolated_packages = getattr(resolution, "isolated_packages", {})
    isolated_git_packages = getattr(resolution, "isolated_git_packages", {})

    # Dependency cycles in the pubspec graph become one merged repository per
    # cycle. The graph needs every hosted package's pubspec, so the extension
    # reads each package once here — from the lockfile facts when unchanged,
    # by downloading it otherwise; the spokes download the same tarballs
    # again (through the shared download cache) when they materialise.
    explicit_package_names = sorted(explicit.keys())
    plan_facts = {}

    shared_sccs, vanished_spokes = _pub_plan_shared_sccs(ctx, resolution, explicit_package_names, plan_facts)

    isolated_hub_names = sorted(set(isolated_packages.keys()) | set(isolated_git_packages.keys()))
    isolated_sccs = {}
    for hub_name in isolated_hub_names:
        isolated_sccs[hub_name] = _pub_plan_isolated_sccs(ctx, hub_name, resolution, explicit_package_names, vanished_spokes, plan_facts)

    # Labels spokes and hubs point at for merged members, per scope.
    shared_scc_targets = {
        member: "@{repo}//:{member}".format(repo = repo, member = member)
        for member, repo in shared_sccs.members.items()
    }

    _pub_emit_explicit(explicit, vanished_spokes)
    _pub_emit_aliased(aliases, vanished_spokes)

    # Create shared spoke repos. Cycle members get no spoke of their own: the
    # merged repository below holds the whole cycle, and every edge into it
    # (mapped through `scc_targets`) names the merged target instead.
    all_package_names = sorted(resolved.keys() + [n for n in resolved_git.keys() if n not in resolved])
    _pub_emit_shared_spokes(resolved, shared_sccs, all_package_names, explicit_package_names, ignore_hooks, shared_scc_targets)
    _pub_emit_shared_merged(shared_sccs, resolved, resolved_git, all_package_names, explicit_package_names, shared_scc_targets, ignore_hooks)
    _pub_emit_shared_git(resolved_git, shared_sccs, all_package_names, explicit_package_names, ignore_hooks, shared_scc_targets)

    for hub_name in isolated_hub_names:
        _pub_emit_isolated_hub(hub_name, isolated_packages, isolated_git_packages, isolated_sccs, explicit_package_names, ignore_hooks)

    _pub_emit_hubs(hub_packages, isolated_hub_names, isolated_sccs, shared_sccs, explicit)

    return _pub_extension_metadata(ctx, root_repos, plan_facts)

pub = module_extension(
    implementation = _pub_impl,
    tag_classes = {
        "package": _package,
        "from_lock": _from_lock,
    },
    doc = "Declares pub.dev package dependencies for download and use as dart_library targets. The root module wins over dependencies: its `pub.package()` pin, or the version its `from_lock` locks settle on, resolves when a dependency declares another version with `pub.package()`, with a NOTE naming the resolved version. A root lock's git entry pins like a hosted one.",
)
