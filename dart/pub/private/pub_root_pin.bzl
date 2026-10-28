"""Root-wins precedence for `pub.package()` declarations.

The root module pins a package with its own `pub.package()` tag or with a
lock its `pub.from_lock()` reads, whether the lock entry is hosted or git.
Isolated hubs never pin: their spokes are namespaced by hub and keep the
versions in their own lock, so only non-isolated root locks count. A non-root
module's `pub.package()` for a pinned package is dropped. A dropped
declaration at another version resolves to the resolved version with an
informational NOTE naming the package, the resolved version and where it
comes from, and each overridden version with the module that declared it.
Under `on_version_conflict = "upgrade"` the resolved version can come from
another lock, and the NOTE names that version, never the root's lower one. A
hosted declaration never matches a git pin, at any version string. A dropped
declaration at the same version with a different sha256 is an integrity
conflict and fails naming both values, as do two dropped declarations or a
dropped declaration and any non-isolated lock entry that share a version with
different sha256 values: a root pin chooses the version, never the hash. A
dropped declaration that agrees is silent. With no root pin, non-root
declarations behave as before: one declaration applies, and disagreeing ones
fail.

`select_pub_package` is the precedence decision, factored pure so Starlark
unit tests can call it with module-shaped input (`is_root`, module name,
declaration fields, lock entry fields). `resolve_pub_packages` in
`//dart/pub:extensions.bzl` calls it once per package name in sorted name
order, so the outcome never depends on module order.
"""

load("//dart/pub:yaml_parser.bzl", "is_valid_git_ref", "is_valid_sha256")
load("//dart/pub/private:pub_repository.bzl", "pub_package_sha256_error")
load("//dart/pub/private:version.bzl", "semver_gt")

def explicit_conflict_error(existing, pkg, sha256):
    """Returns the conflict error for a repeated `pub.package()`, or None.

    Args:
      existing: The stored declaration struct with `(version, sha256, deps)`.
      pkg: The new declaration struct with `(name, version, deps)`.
      sha256: The new declaration's stripped sha256.

    Returns:
      The conflict error string, or None when the declarations agree.
    """
    if existing.version != pkg.version:
        return (
            "Package \"%s\" has conflicting versions across pub.package() declarations:\n" % pkg.name +
            "  - %s (sha256: %s)\n" % (existing.version, existing.sha256) +
            "  - %s (sha256: %s)" % (pkg.version, sha256)
        )
    if existing.sha256 != sha256:
        return (
            "Package \"%s\" (%s) has conflicting sha256 checksums across pub.package() declarations:\n" % (pkg.name, pkg.version) +
            "  - %s\n" % existing.sha256 +
            "  - %s" % sha256
        )
    if sorted(existing.deps) != sorted(pkg.deps):
        return (
            "Package \"%s\" (%s) has conflicting deps across pub.package() declarations:\n" % (pkg.name, pkg.version) +
            "  - %s\n" % existing.deps +
            "  - %s" % pkg.deps
        )
    return None

def decl_lock_sha_conflict(name, version, decl_sha, hub_name, lock_label, lock_sha):
    """Returns the declaration-vs-lock sha256 conflict error.

    This is the wording lock collection reports when a `pub.package()`
    declaration and a lock entry share a version with different hashes. The
    root-pin decision reuses it for dropped declarations, so a root pin
    never hides the conflict behind a different message.

    Args:
      name: The package name.
      version: The shared package version.
      decl_sha: The declaration's sha256.
      hub_name: The hub name of the lock holding the entry.
      lock_label: The label of the lock holding the entry.
      lock_sha: The lock entry's sha256.

    Returns:
      The conflict error string.
    """
    return (
        "Package \"%s\" (%s) has conflicting sha256 checksums between pub.package() and %s:\n" % (name, version, lock_label) +
        "  - %s (from pub.package)\n" % decl_sha +
        "  - %s (from \"%s\", %s)" % (lock_sha, hub_name, lock_label)
    )

def git_ref_conflict(name, entries):
    """Returns the cross-lock resolved-ref conflict error, or None.

    Args:
      name: The package name the entries resolve.
      entries: The lock entry structs with `(version, resolved_ref,
        hub_name, lock_label)`.

    Returns:
      The conflict error string, or None when no version carries two
      resolved refs.
    """
    by_version = {}
    for e in entries:
        if e.version not in by_version:
            by_version[e.version] = e
        elif by_version[e.version].resolved_ref != e.resolved_ref:
            first = by_version[e.version]
            return (
                "Package \"%s\" (%s) has conflicting resolved-ref values across lock files:\n" % (name, e.version) +
                "  - %s (from \"%s\", %s)\n" % (first.resolved_ref, first.hub_name, first.lock_label) +
                "  - %s (from \"%s\", %s)" % (e.resolved_ref, e.hub_name, e.lock_label)
            )
    return None

def git_path_conflict(name, entries):
    """Returns the cross-lock git path conflict error, or None.

    Two entries for the same package version and resolved ref that point at
    different `path` values inside the repository resolve different sources,
    so they are an error naming the package, both paths, and both locks'
    hub name and lock label, in either lock order. Entries that agree on the
    version, resolved ref and path still deduplicate silently.

    Args:
      name: The package name the entries resolve.
      entries: The lock entry structs with `(version, resolved_ref, path,
        hub_name, lock_label)`.

    Returns:
      The conflict error string, or None when no version and ref carries
      two paths.
    """
    by_version = {}
    for e in entries:
        key = (e.version, e.resolved_ref)
        if key not in by_version:
            by_version[key] = e
        elif str(by_version[key].path) != str(e.path):
            first = by_version[key]
            return (
                "Package \"%s\" (%s) has conflicting git paths across lock files:\n" % (name, e.version) +
                "  - %s (from \"%s\", %s)\n" % (first.path, first.hub_name, first.lock_label) +
                "  - %s (from \"%s\", %s)" % (e.path, e.hub_name, e.lock_label)
            )
    return None

def git_version_error(name, entries):
    """Returns the version-conflict error for git packages."""
    return (
        "Package \"%s\" has conflicting versions across lock files:\n" % name +
        "".join([
            "  - %s (from \"%s\", %s)\n" % (entry.version, entry.hub_name, entry.lock_label)
            for entry in entries
        ])
    )

def hosted_sha_conflict(name, entries):
    """Returns the cross-lock sha256 conflict error, or None.

    Args:
      name: The package name the entries resolve.
      entries: The lock entry structs with `(version, sha256, hub_name,
        lock_label)`.

    Returns:
      The conflict error string, or None when no version carries two
      sha256 values.
    """

    # Conflicting sha256 values for the same package version across locks
    # are an error, even when that version is later superseded by a higher
    # version or by an explicit pub.package().
    by_version = {}
    for e in entries:
        if e.version not in by_version:
            by_version[e.version] = e
        elif by_version[e.version].sha256 != e.sha256:
            first = by_version[e.version]
            return (
                "Package \"%s\" (%s) has conflicting sha256 checksums across lock files:\n" % (name, e.version) +
                "  - %s (from \"%s\", %s)\n" % (first.sha256, first.hub_name, first.lock_label) +
                "  - %s (from \"%s\", %s)" % (e.sha256, e.hub_name, e.lock_label)
            )
    return None

def best_entry(entries):
    """Returns the highest-version entry.

    Args:
      entries: The non-empty lock entry structs with `version`.

    Returns:
      The entry with the highest version (the first on ties).
    """
    best = entries[0]
    for e in entries[1:]:
        if semver_gt(e.version, best.version):
            best = e
    return best

def hosted_version_error(name, entries, best):
    """Returns the version-conflict error for hosted packages."""
    return (
        "Package \"%s\" has conflicting versions across lock files:\n" % name +
        "".join([
            "  - %s (from \"%s\", %s)\n" % (entry.version, entry.hub_name, entry.lock_label)
            for entry in entries
        ]) +
        "\nThe pubspec.lock files pinned different versions of a shared transitive\n" +
        "package. `dart pub get` preserves existing locked versions, so it won't\n" +
        "bring them back into sync. To resolve:\n" +
        "\n" +
        "  1. (Preferred) Run `dart pub upgrade` in the workspace with the lower\n" +
        "     version. This re-resolves transitive packages within their constraints,\n" +
        "     pulling the shared dependency forward to match.\n" +
        "\n" +
        "  2. If constraints prevent the upgrade, set on_version_conflict = \"upgrade\"\n" +
        "     on the from_lock() call with the lower version, allowing it to accept\n" +
        "     the higher.\n" +
        "\n" +
        "  3. Or pin centrally with an explicit declaration:\n" +
        "       pub.package(name = \"%s\", version = \"%s\", sha256 = \"%s\", deps = [...])\n" % (name, best.version, best.sha256) +
        "       # You may need to manually add deps for this package.\n" +
        "\nrules_dart does not support multiple versions of a package, even across lock files."
    )

def decls_by_name(package_tags):
    """Groups `pub.package()` tags by package name, preserving tag order.

    Args:
      package_tags: The `package` tags, each with `(name, version, sha256,
        deps, package_files)` and optionally `(is_root, module)`.

    Returns:
      Dict of package name to that package's declaration structs in tag
      order.
    """
    by_name = {}
    for tag in package_tags:
        by_name.setdefault(tag.name, []).append(struct(
            is_root = getattr(tag, "is_root", True),
            module = getattr(tag, "module", ""),
            name = tag.name,
            version = tag.version,
            sha256 = tag.sha256,
            deps = tag.deps,
            package_files = getattr(tag, "package_files", ["pubspec.yaml", "LICENSE*"]),
        ))
    return by_name

def _hosted_pin_entry(info, tag):
    """Returns the hosted pin entry struct, or None when it cannot pin.

    Only well-formed entries (with a valid sha256) pin: a malformed entry
    is left for lock collection to report.
    """
    if info.get("source", "unknown") != "hosted":
        return None
    sha256 = info.get("description", {}).get("sha256", "")
    if not is_valid_sha256(sha256):
        return None
    return struct(
        version = info.get("version", ""),
        sha256 = sha256.strip(),
        hub_name = tag.name,
        lock_label = str(tag.lock),
        on_version_conflict = tag.on_version_conflict,
    )

def _git_pin_entry(info, tag):
    """Returns the git pin entry struct, or None when it cannot pin.

    Only well-formed entries (with a valid `resolved-ref`) pin. The struct
    carries the ref, path and url because a git pin has no sha256.
    """
    if info.get("source", "unknown") != "git":
        return None
    desc = info.get("description", {})
    raw_ref = desc.get("resolved-ref", "")
    ref = raw_ref.strip() if type(raw_ref) == "string" else ""
    if not is_valid_git_ref(ref):
        return None
    path = desc.get("path", ".")
    if path == None or str(path).strip() == "":
        path = "."
    return struct(
        version = info.get("version", ""),
        resolved_ref = ref,
        path = path,
        url = desc.get("url", ""),
        hub_name = tag.name,
        lock_label = str(tag.lock),
        on_version_conflict = tag.on_version_conflict,
    )

def _collect_source_entries(lock_tags, root_only, source):
    """Collects non-isolated `from_lock` entries of one source, in stable order.

    Only well-formed entries pin: a malformed entry is left for lock
    collection to report, so its error keeps today's wording instead of
    surfacing as a pin conflict. Hosted entries need a valid sha256, git
    entries a valid `resolved-ref`. Git entries carry no sha256, so they
    need their own shape rather than the hosted entry struct.

    Args:
      lock_tags: The `from_lock` tags, each with `(name, lock, packages,
        on_version_conflict, isolated)` and optionally `(is_root, module)`.
        Tags without `is_root` count as root, matching `pub.package()`
        tags from before module tracking.
      root_only: When True, keeps only the root module's tags; otherwise
        keeps every module's tags.
      source: The lock `source` to collect (`"hosted"` or `"git"`).

    Returns:
      Dict of package name to that source's entry structs, sorted by lock
      label and hub name so ties never depend on module order. Hosted
      entries carry `(version, sha256, hub_name, lock_label,
      on_version_conflict)`; git entries carry `(version, resolved_ref,
      path, url, hub_name, lock_label, on_version_conflict)`.
    """
    by_name = {}
    for tag in lock_tags:
        if getattr(tag, "isolated", False):
            continue
        if root_only and not getattr(tag, "is_root", True):
            continue
        for name in sorted(tag.packages.keys()):
            if source == "hosted":
                entry = _hosted_pin_entry(tag.packages[name], tag)
            else:
                entry = _git_pin_entry(tag.packages[name], tag)
            if entry == None:
                continue
            by_name.setdefault(name, []).append(entry)
    for name in by_name.keys():
        keyed = [(e.lock_label + "\n" + e.hub_name + "\n" + e.version, i, e) for i, e in enumerate(by_name[name])]
        by_name[name] = [e for (_, _, e) in sorted(keyed)]
    return by_name

def root_hosted_lock_entries(lock_tags):
    """Maps package name to the root's non-isolated hosted lock entries.

    Only well-formed entries (with a valid sha256) pin: a malformed root
    lock entry is left for lock collection to report, so its error keeps
    today's wording instead of surfacing as a pin conflict.

    Args:
      lock_tags: The `from_lock` tags, each with `(name, lock, packages,
        on_version_conflict, isolated)` and optionally `(is_root, module)`.
        Tags without `is_root` count as root, matching `pub.package()`
        tags from before module tracking.

    Returns:
      Dict of package name to the root's hosted entry structs `(version,
      sha256, hub_name, lock_label, on_version_conflict)`, sorted by lock
      label and hub name so ties never depend on module order.
    """
    return _collect_source_entries(lock_tags, True, "hosted")

def root_git_lock_entries(lock_tags):
    """Maps package name to the root's non-isolated git lock entries.

    A root git entry pins its package just as a hosted entry does. Only
    well-formed entries (with a valid `resolved-ref`) pin, and isolated
    root hubs never pin, git entries included.

    Args:
      lock_tags: The `from_lock` tags (see `root_hosted_lock_entries`).

    Returns:
      Dict of package name to the root's git entry structs `(version,
      resolved_ref, path, url, hub_name, lock_label,
      on_version_conflict)`, sorted by lock label and hub name.
    """
    return _collect_source_entries(lock_tags, True, "git")

def nonisolated_hosted_entries(lock_tags):
    """Maps package name to every non-isolated hosted lock entry.

    Covers every module's locks, so the pin decision can name the version
    that actually resolves and can still report a dropped declaration's
    same-version sha256 mismatch.

    Args:
      lock_tags: The `from_lock` tags (see `root_hosted_lock_entries`).

    Returns:
      Dict of package name to hosted entry structs, sorted as in
      `root_hosted_lock_entries`.
    """
    return _collect_source_entries(lock_tags, False, "hosted")

def nonisolated_git_entries(lock_tags):
    """Maps package name to every non-isolated git lock entry.

    Args:
      lock_tags: The `from_lock` tags (see `root_hosted_lock_entries`).

    Returns:
      Dict of package name to git entry structs, sorted as in
      `root_git_lock_entries`.
    """
    return _collect_source_entries(lock_tags, False, "git")

def _fold_same_level(decls):
    """Folds same-precedence declarations to one winner. Returns (winner, error)."""
    winner = None
    for decl in decls:
        if winner == None:
            winner = decl
            continue
        err = explicit_conflict_error(winner, decl, decl.sha256)
        if err:
            return None, err
    return winner, None

def _lock_pin(name, entries):
    """Settles the root's lock pin with today's cross-lock rules.

    Returns (pin, error): `pin` is `struct(version, sha256, source)` with
    the winning entry's lock label as source, or None when `entries` is
    empty; `error` is today's cross-lock message when the root's own locks
    disagree.
    """
    if not entries:
        return None, None
    err = hosted_sha_conflict(name, entries)
    if err:
        return None, err
    best = best_entry(entries)
    for e in entries:
        if e.version != best.version and e.on_version_conflict == "error":
            return None, hosted_version_error(name, entries, best)
    return struct(version = best.version, sha256 = best.sha256, source = best.lock_label), None

def _git_pin(name, entries):
    """Settles the root's git pin with today's cross-lock rules.

    Returns (pin, error): `pin` is `struct(kind, version, resolved_ref,
    path, source)` with the winning entry's lock label as source, or None
    when `entries` is empty; `error` is today's cross-lock message when the
    root's own locks disagree.
    """
    if not entries:
        return None, None
    err = git_ref_conflict(name, entries)
    if err:
        return None, err
    best = best_entry(entries)
    for e in entries:
        if e.version != best.version and e.on_version_conflict == "error":
            return None, git_version_error(name, entries)
    return struct(kind = "git", version = best.version, resolved_ref = best.resolved_ref, path = best.path, source = best.lock_label), None

def global_best(entries):
    """Returns the version-resolution winner across every non-isolated lock, or None.

    Mirrors the `on_version_conflict` choice the lock scopes apply: the
    highest version wins, unless a lower version's lock says `error`. None
    means the global pass reports the conflict itself, so the pin keeps
    today's source and the error keeps today's wording.

    Args:
      entries: Every non-isolated lock entry for the package, each with
        `(version, on_version_conflict)`.

    Returns:
      The winning entry, or None when empty or conflicting under `error`.
    """
    if not entries:
        return None
    best = best_entry(entries)
    for e in entries:
        if e.version != best.version and e.on_version_conflict == "error":
            return None
    return best

def _root_decl_lock_error(name, root_decl, entries):
    """Returns today's explicit-vs-lock sha error for the root pin, or None."""
    for e in entries:
        if e.version == root_decl.version and e.sha256 != root_decl.sha256:
            return (
                "Package \"%s\" (%s) has conflicting sha256 checksums between pub.package() and %s:\n" % (name, e.version, e.lock_label) +
                "  - %s (from pub.package)\n" % root_decl.sha256 +
                "  - %s (from \"%s\", %s)" % (e.sha256, e.hub_name, e.lock_label)
            )
    return None

def _overridden_note(name, pin_version, pin_source, overridden):
    """Formats the NOTE naming the pin and each overridden declaration."""
    frags = sorted([(decl.module, decl.version) for decl in overridden])
    return (
        "Pub package \"%s\" uses %s from %s, not %s." % (
            name,
            pin_version,
            pin_source,
            "; ".join(["%s declared by module \"%s\"" % (version, module) for (module, version) in frags]),
        )
    )

def _drop_dep_decls(name, pin, pin_source, dep_decls):
    """Drops non-root declarations against the root pin. Returns (note, error)."""
    overridden = []
    for decl in dep_decls:
        if decl.version != pin.version:
            overridden.append(decl)
        elif decl.sha256 != pin.sha256:
            return None, (
                "Package \"%s\" (%s) has conflicting sha256 checksums between the root module's pin from %s and pub.package() from module \"%s\":\n" % (name, decl.version, pin_source, decl.module) +
                "  - %s (from %s)\n" % (pin.sha256, pin_source) +
                "  - %s (from module \"%s\")" % (decl.sha256, decl.module)
            )
    if not overridden:
        return None, None
    return _overridden_note(name, pin.version, pin_source, overridden), None

def _git_overridden_note(name, pin_version, resolved_ref, pin_source, overridden):
    """Formats the NOTE naming the git pin and each overridden declaration."""
    frags = sorted([(decl.module, decl.version) for decl in overridden])
    return (
        "Pub package \"%s\" uses %s from git %s in %s, not %s." % (
            name,
            pin_version,
            resolved_ref,
            pin_source,
            "; ".join(["%s declared by module \"%s\"" % (version, module) for (module, version) in frags]),
        )
    )

def _drop_dep_decls_for_git(name, pin, dep_decls):
    """Drops every non-root declaration against a root git pin. Returns (note, error).

    A hosted `pub.package()` never matches a git pin, even at the pin's own
    version string, so every dependency declaration is overridden. Never
    fails: a hosted archive hash and a git commit are incomparable.
    """
    if not dep_decls:
        return None, None
    return _git_overridden_note(name, pin.version, pin.resolved_ref, pin.source, dep_decls), None

def dep_decl_sha_conflicts(name, dep_decls):
    """Returns the same-version declaration conflict error, or None.

    A root pin drops version differences, but declarations at one version
    still face the check they would face without it, with the same wording.

    Args:
      name: The package name.
      dep_decls: The non-root declarations, each with `(module, version,
        sha256, deps)`.

    Returns:
      The `explicit_conflict_error` string for the first same-version
      disagreement in sorted version order, or None.
    """
    ordered = sorted([(decl.version, decl.module, i, decl) for i, decl in enumerate(dep_decls)])
    winner = None
    for (_, _, _, decl) in ordered:
        if winner == None or winner.version != decl.version:
            winner = decl
            continue
        err = explicit_conflict_error(winner, decl, decl.sha256)
        if err:
            return err
    return None

def dropped_decl_lock_conflicts(name, dep_decls, lock_entries):
    """Returns the declaration-vs-lock sha256 error with collection wording, or None.

    A dropped declaration still faces every same-version lock check it
    would face without a root pin: the first mismatch in sorted
    (module, version) declaration order fails exactly as lock collection
    words it.

    Args:
      name: The package name.
      dep_decls: The non-root declarations with `(module, version,
        sha256)`.
      lock_entries: Every non-isolated hosted lock entry for the package,
        each with `(version, sha256, hub_name, lock_label)`, in stable
        order.

    Returns:
      The `decl_lock_sha_conflict` string, or None.
    """
    ordered = sorted([(decl.module, decl.version, i, decl) for i, decl in enumerate(dep_decls)])
    for (_, _, _, decl) in ordered:
        for e in lock_entries:
            if e.version == decl.version and e.sha256 != decl.sha256:
                return decl_lock_sha_conflict(name, decl.version, decl.sha256, e.hub_name, e.lock_label, e.sha256)
    return None

def _checked_decls(decls):
    """Validates archive hashes and strips them. Returns (clean, error, error_shape)."""
    for decl in decls:
        err = pub_package_sha256_error(decl.name, decl.version, decl.sha256)
        if err:
            return [], err, "sha"
    clean = [struct(
        is_root = decl.is_root,
        module = decl.module,
        name = decl.name,
        version = decl.version,
        sha256 = decl.sha256.strip(),
        deps = decl.deps,
        package_files = getattr(decl, "package_files", ["pubspec.yaml", "LICENSE*"]),
    ) for decl in decls]
    return clean, None, ""

def _select_with_root_decl(name, root_decl, dep_decls, root_entries, all_hosted):
    """Resolves against the root module's own `pub.package()` pin. Returns the selection struct."""
    pin = struct(version = root_decl.version, sha256 = root_decl.sha256, source = "the root module's pub.package()")
    err = _root_decl_lock_error(name, pin, root_entries)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    scoped = all_hosted if all_hosted != None else root_entries
    err = dep_decl_sha_conflicts(name, dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    err = dropped_decl_lock_conflicts(name, dep_decls, scoped)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    note, err = _drop_dep_decls(name, pin, pin.source, dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    return struct(
        selected = struct(version = root_decl.version, sha256 = root_decl.sha256, deps = root_decl.deps, package_files = root_decl.package_files, source = pin.source),
        alias = None,
        note = note,
        error = None,
        error_shape = "",
    )

def _select_with_hosted_pin(name, pin, dep_decls, all_hosted):
    """Resolves against a root hosted lock pin at the globally resolved version. Returns the selection struct."""
    if all_hosted != None:
        winner = global_best(all_hosted)
        if winner != None and winner.version != pin.version:
            pin = struct(version = winner.version, sha256 = winner.sha256, source = winner.lock_label)
    note, err = _drop_dep_decls(name, pin, pin.source, dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    err = dep_decl_sha_conflicts(name, dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if all_hosted != None:
        err = dropped_decl_lock_conflicts(name, dep_decls, all_hosted)
        if err:
            return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if dep_decls:
        alias = struct(version = pin.version, sha256 = pin.sha256, source = pin.source)
    else:
        alias = None
    return struct(selected = None, alias = alias, note = note, error = None, error_shape = "")

def _select_with_git_pin(name, pin, dep_decls, all_hosted, all_git):
    """Resolves against a root git lock pin at the globally resolved ref. Returns the selection struct."""
    if all_git != None:
        winner = global_best(all_git)
        if winner != None and winner.version != pin.version:
            pin = struct(kind = "git", version = winner.version, resolved_ref = winner.resolved_ref, path = winner.path, source = winner.lock_label)
    err = dep_decl_sha_conflicts(name, dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if all_hosted != None:
        err = dropped_decl_lock_conflicts(name, dep_decls, all_hosted)
        if err:
            return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    note, _kept = _drop_dep_decls_for_git(name, pin, dep_decls)
    if dep_decls:
        alias = struct(version = pin.version, sha256 = "", resolved_ref = pin.resolved_ref, path = pin.path, source = pin.source)
    else:
        alias = None
    return struct(selected = None, alias = alias, note = note, error = None, error_shape = "")

def select_all_explicit(package_tags, lock_tags):
    """Resolves every `pub.package()` name with root-wins precedence.

    Args:
      package_tags: The `package` tags, each with `(name, version, sha256,
        deps)` and optionally `(is_root, module)`. Tags without `is_root`
        count as root.
      lock_tags: The `from_lock` tags (see `root_hosted_lock_entries`).

    Returns:
      `(explicit, aliases, notes, error, error_shape)`: `explicit` maps
      package name to the winning `(name, version, sha256, deps,
      package_files)` struct, a repository the extension generates under the
      package name;
      `aliases` maps package name to `(version, sha256, source)` for names
      a root hosted lock pin resolves while declarations exist, or to
      `(version, resolved_ref, path, source)` for names a root git lock pin
      resolves: the extension generates the package-named repository as an
      alias to the lock spoke, so modules importing the name keep loading
      at the resolved version; `notes` holds one NOTE per package whose
      root pin overrode a different version, naming the version that
      actually resolves; `error` with `error_shape` (`"sha"` or
      `"conflict"`) reports the first failure in sorted package name order.
    """
    grouped = decls_by_name(package_tags)
    pins = root_hosted_lock_entries(lock_tags)
    git_pins = root_git_lock_entries(lock_tags)
    every_hosted = nonisolated_hosted_entries(lock_tags)
    every_git = nonisolated_git_entries(lock_tags)
    explicit = {}
    aliases = {}
    notes = []
    for name in sorted(grouped.keys()):
        sel = select_pub_package(
            name,
            grouped[name],
            pins.get(name, []),
            git_pins.get(name, []),
            every_hosted.get(name, []),
            every_git.get(name, []),
        )
        if sel.error:
            return {}, {}, [], sel.error, sel.error_shape
        if sel.note:
            notes.append(sel.note)
        if sel.selected != None:
            explicit[name] = struct(
                name = name,
                version = sel.selected.version,
                sha256 = sel.selected.sha256,
                deps = sel.selected.deps,
                package_files = sel.selected.package_files,
            )
        elif sel.alias != None:
            aliases[name] = sel.alias
    return explicit, aliases, notes, None, ""

def select_pub_package(name, decls, root_entries, root_git_entries = [], all_hosted_entries = None, all_git_entries = None):
    """Resolves the winning `pub.package()` declaration for one package.

    A root git pin counts like a hosted one: every non-root declaration is
    dropped at any version, the package resolves to the git spoke, and the
    NOTE names the git version and ref. Under `upgrade` the NOTE and the
    alias carry the version that actually resolves across every
    non-isolated lock, never the root's lower one. Dropped declarations
    still face their same-version sha256 checks against other declarations
    and every non-isolated lock entry. The root module's own `pub.package()`
    still wins over its own locks exactly as before.

    Args:
      name: The package name.
      decls: Every `pub.package()` tag for the package, each with
        `(is_root, module, name, version, sha256, deps, package_files)`, in
        any order.
      root_entries: The root's non-isolated hosted lock entries for the
        package (see `root_hosted_lock_entries`), in any order.
      root_git_entries: The root's non-isolated git lock entries for the
        package (see `root_git_lock_entries`), in any order.
      all_hosted_entries: Every non-isolated hosted lock entry for the
        package, in any order. None keeps the caller that only knows the
        root's entries on today's behaviour.
      all_git_entries: Every non-isolated git lock entry for the package,
        in any order. None keeps today's behaviour.

    Returns:
      `struct(selected, alias, note, error, error_shape)`: `selected` is the
      winning declaration `(version, sha256, deps, package_files, source)` or
      None when no `pub.package()` applies (the locks resolve the package);
      `alias` is
      `(version, sha256, source)` for a hosted pin, or `(version,
      resolved_ref, path, source)` for a git pin, when declarations exist
      but a root lock pin resolves the package, telling the caller to
      generate the package-named repository as an alias to the lock spoke
      at the resolved version, or None otherwise; `note` is the
      informational NOTE when a root pin overrides a different version;
      `error` with `error_shape` (`"sha"` or `"conflict"`) reports the
      failure.
    """
    clean, err, shape = _checked_decls(decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = shape)
    root_decls = [decl for decl in clean if decl.is_root]
    dep_decls = [decl for decl in clean if not decl.is_root]
    root_decl, err = _fold_same_level(root_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if root_decl:
        return _select_with_root_decl(name, root_decl, dep_decls, root_entries, all_hosted_entries)
    pin, err = _lock_pin(name, root_entries)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    git_pin, err = _git_pin(name, root_git_entries)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if git_pin != None:
        return _select_with_git_pin(name, git_pin, dep_decls, all_hosted_entries, all_git_entries)
    if pin != None:
        return _select_with_hosted_pin(name, pin, dep_decls, all_hosted_entries)
    winner, err = _fold_same_level(dep_decls)
    if err:
        return struct(selected = None, alias = None, note = None, error = err, error_shape = "conflict")
    if winner == None:
        return struct(selected = None, alias = None, note = None, error = None, error_shape = "")
    return struct(
        selected = struct(version = winner.version, sha256 = winner.sha256, deps = winner.deps, package_files = winner.package_files, source = "pub.package() from module \"%s\"" % winner.module),
        alias = None,
        note = None,
        error = None,
        error_shape = "",
    )
