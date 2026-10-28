"""Diagnostics for packages a lock lists but the build does not materialize.

The `pub` module extension collects every lock's entries before it can resolve
anything. A non-hosted entry gets no repository, which is legal but leaves a
`package:` import unresolved at analysis time; this file owns the one warning
that says so, split out of the extension file because that file is over its
size limit and a new feature must not make it grow.
"""

def warn_skipped_sources(state, lock_tag, hub_name, skipped_by_source):
    """Warns once per lock file about non-hosted packages getting no repository.

    Args:
      state: The mutable resolution state; the warning is appended to its
        `warnings` list.
      lock_tag: The `from_lock` tag whose entries were collected.
      hub_name: The hub the lock contributes to, named in the warning.
      skipped_by_source: Dict of lock `source` to the sorted package names
        skipped for it.
    """

    # Only hosted packages can be fetched from a pub registry. Collect
    # every non-hosted package and report once per lock file.
    if not skipped_by_source:
        return
    details = []
    for source in sorted(skipped_by_source.keys()):
        if source == "sdk":
            remedy = "provided by the Dart/Flutter SDK, not fetched by pub"
        else:
            remedy = "declare via pub.package() or a local dart_library"
        details.append("  - %s (%s): %s" % (
            source,
            remedy,
            ", ".join(sorted(skipped_by_source[source])),
        ))

    state["warnings"].append(
        ("pub.from_lock(%s): %s lists non-hosted packages; no repository " +
         "is created for them, so `package:` imports of these packages " +
         "will fail to resolve unless they are provided another way:\n%s") % (
            hub_name,
            lock_tag.lock,
            "\n".join(details),
        ),
    )
