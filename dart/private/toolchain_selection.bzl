"""Picks one Dart SDK version per toolchain name from the versions modules request."""

def _parse_version(v):
    """Splits a version string into a list of ints for comparison."""
    return [int(x) for x in v.split(".")]

def select_toolchain_version(name, requests):
    """Selects the Dart SDK version for one toolchain name.

    The root module's request wins when it makes one: a root pin is selected
    even when a dependency (rules_dart's included) requests a newer SDK. With
    no root request, the highest requested version wins, as before.

    When several root tags request the same name, the highest of the root's own
    requests is used.

    Args:
      name: The toolchain name, used in the note.
      requests: Non-empty list of `struct(version, is_root)`, one per tag.

    Returns:
      `struct(version, note)`. `note` is a message for the user when the root
      module pinned a version older than a dependency's request (the root still
      wins), and None otherwise.
    """
    root_requests = [r for r in requests if r.is_root]
    dep_requests = [r for r in requests if not r.is_root]

    if root_requests:
        selected = root_requests[0].version
        for request in root_requests[1:]:
            if _parse_version(request.version) > _parse_version(selected):
                selected = request.version

        # The root pin wins even when it is older than a dependency's request;
        # surface that as an informational note naming both versions.
        newer_dep_versions = [
            r.version for r in dep_requests
            if _parse_version(r.version) > _parse_version(selected)
        ]
        note = None
        if newer_dep_versions:
            newest_dep = newer_dep_versions[0]
            for v in newer_dep_versions[1:]:
                if _parse_version(v) > _parse_version(newest_dep):
                    newest_dep = v
            note = "Dart toolchain {} uses {} requested by the root module, which is older than {} requested by a dependency".format(
                name,
                selected,
                newest_dep,
            )
        return struct(version = selected, note = note)

    # No root request: highest requested version wins.
    selected = requests[0].version
    for request in requests[1:]:
        if _parse_version(request.version) > _parse_version(selected):
            selected = request.version
    return struct(version = selected, note = None)