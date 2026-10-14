"""Hermetic staged-project assembly for rules that need a real project layout.

`dart compile js|wasm` accepts no `--packages` flag and `dart analyze` wants a
project directory, so both resolve packages by walking up from their input to a
`.dart_tool/package_config.json`. This module stages that layout entirely from
declared artifacts — no `mktemp`, no shell — as sibling outputs:

    <name>.proj/.dart_tool/package_config.json   (declared file)
    <name>.proj/src/...                          (tree artifact; workspace-relative paths)
    <name>.proj/src/<lib_root>/pubspec.yaml      (stub, one per main-repo package)
    <name>.extpkgs/<pkg>/...                     (external packages, copy mode only)

Main-repo sources (hand-written and generated) merge into one `src` tree at
their workspace-relative paths, so every main-repo package's `lib_root` is a
real directory under `src/`.

External (pub) packages are laid out one of two ways, chosen by
`stage_dart_project`'s `copy_external`. Package resolution follows rootUris
outside the project dir in both.

- Copy (`copy_external = True`, the default). Each external package gets its
  own tree artifact, `<name>.extpkgs/<pkg>`, referenced from the config by a
  `../../` rootUri. External (pub) packages cannot share the `src` tree:
  `copy_to_directory` maps external files repo-relative, so two pub spokes
  would collide at `lib/...`. `dart_format` copies. It reads its staged project
  from runfiles, where external repositories do not sit at the path a relative
  rootUri into `external/` would name, so the staged config must carry the
  files itself.
- Direct (`copy_external = False`). A pub package already sits in one real
  directory, its spoke repository at `external/<repo>[/<sub>]`. The config's
  rootUri is the relative path from `<name>.proj/.dart_tool` to that directory,
  and the package's files are declared as inputs of the consuming action
  instead of being copied. Nothing is copied per analyzed target: a test that
  depends on `package:test` would otherwise copy about 50 pub packages for each
  of its analysis, fix and compile actions. The `dart_analyze` aspect and
  `dart_web_application` use this mode. A package whose files do not all sit in
  one directory is copied even so; see `external_package_placement`.

Each main-repo package root also receives a stub `pubspec.yaml`. Imports
resolve through `package_config.json` alone, but the analyzer attributes a
file to a package by walking up to the *nearest enclosing pubspec.yaml*
(`findPackageFor` in `pkg/analyzer`'s pub workspace), and a family of lints —
`public_member_api_docs`, `always_use_package_imports`,
`prefer_relative_imports`, `avoid_renaming_method_parameters`, and every rule
consulting `WorkspacePackage.contains` — decides whether to fire from that
package's root (`isInLibDir` is `<package root>/lib` containing the file).
With only a project-level pubspec, a staged file's "package root" would be
`<name>.proj` itself, its path relative to it `src/<lib_root>/lib/…`, and
those lints silently decline. The stubs restore each package's true root; a
nested pubspec does not split analysis contexts (context roots split on
options/package_config files, not pubspecs — `ContextLocatorImpl`, verified
on Dart 3.12.2), so options still come from the nearest `analysis_options.yaml`
above each file, never from a pubspec's position.
"""

load("//dart/private:common.bzl", "package_exec_root", "relative_path")
load("//dart/private:source_set.bzl", "assemble_source_dir", "package_for_index", "package_index")

def mangle_package_dir(name):
    """Returns `name` with path-hostile characters replaced for use as a dir name.

    Args:
      name: A Dart package name (or any string).

    Returns:
      The mangled string (`/`, `:`, `.`, `+` become `_`).
    """
    for ch in ["/", ":", ".", "+"]:
        name = name.replace(ch, "_")
    return name

def _external_sub_path(lib_root):
    """Returns the repo-relative directory of an external `lib_root`.

    An external `lib_root` is `../<repo>[/<sub>]`; `copy_to_directory` stages
    external files at their repo-relative paths, so the package root inside
    its staged tree is `<sub>` (usually empty — pub spokes keep `lib/` at the
    repo root).

    Args:
      lib_root: The external package's `lib_root` (`../`-prefixed).

    Returns:
      The repo-relative sub path string (possibly empty).
    """
    parts = lib_root.split("/")
    return "/".join(parts[2:])

def staged_package_config_content(packages, ext_staged, proj_name, ext_roots = {}, config_dir = ""):
    """Builds package_config.json content for the staged-project layout.

    The config lives at `<proj_name>.proj/.dart_tool/package_config.json`:
    main-repo packages resolve to `../src[/<lib_root>]`. An external package
    named in `ext_roots` resolves to the relative path from the config's
    directory to its exec-root directory. Every other external package resolves
    to its copied tree, `../../<proj_name>.extpkgs/<mangled>[/<sub>]`.

    Args:
      packages: List of DartPackageInfo providers.
      ext_staged: Dict of package_name -> True for external packages that
        have files in the project (those without are skipped — nothing to
        point at).
      proj_name: The staging name prefix (the rule's label name). Names the
        copied trees.
      ext_roots: Dict of package_name -> exec-root-relative directory, for the
        external packages referenced in place (see
        `external_package_placement`). Empty when every package is copied.
      config_dir: The exec-root-relative directory the config is written into;
        the referenced rootUris are relative to it.

    Returns:
      String content of the package_config.json file.
    """
    entries = []
    for pkg in packages:
        if pkg.lib_root.startswith("../"):
            if pkg.package_name not in ext_staged:
                continue
            if pkg.package_name in ext_roots:
                root_uri = relative_path(config_dir, ext_roots[pkg.package_name])
            else:
                root_uri = "../../{}.extpkgs/{}".format(
                    proj_name,
                    mangle_package_dir(pkg.package_name),
                )
                sub = _external_sub_path(pkg.lib_root)
                if sub:
                    root_uri += "/" + sub
        elif pkg.lib_root:
            root_uri = "../src/" + pkg.lib_root
        else:
            root_uri = "../src"
        lv = ""
        if hasattr(pkg, "language_version") and pkg.language_version:
            lv = ', "languageVersion": "{lv}"'.format(lv = pkg.language_version)
        entries.append(
            '    {{"name": "{name}", "rootUri": "{root_uri}", "packageUri": "lib/"{lv}}}'.format(
                name = pkg.package_name,
                root_uri = root_uri,
                lv = lv,
            ),
        )
    return '{{\n  "configVersion": 2,\n  "packages": [\n{packages}\n  ]\n}}\n'.format(
        packages = ",\n".join(entries),
    )

def pubspec_stub(packages, name = "analyze_stub", sdk_version = ""):
    """Builds a `pubspec.yaml` for the staged project or a package within it.

    The analyzer resolves imports through `package_config.json`, never through
    this file — but lint rules read it, so it has to be a *valid* pubspec, not
    just a parseable one. A placeholder name trips `package_names`, and every
    cross-package import trips `depend_on_referenced_packages` unless the
    package is listed here. Both fire on the harness rather than on the code
    under analysis, so a strict ruleset would blame the user for rules_dart's
    staging. Dependencies are sorted because `sort_pub_dependencies` would be
    the next one.

    Constraints are `any`: nothing resolves them, and a real constraint here
    would be a second place to keep a version in sync. The stub's own name is
    excluded from the dependency list; `depend_on_referenced_packages`
    special-cases the containing package, so a `package:self/…` import never
    needs a self-dependency (measured on Dart 3.12.2).

    The SDK constraint is `^<language_version>.0` for the package named
    `name` when it states a `language_version` (which is itself derived from
    the package's real constraint), so `sdk_version_since` judges the code
    against what the package declares. Otherwise it is `^<major>.<minor>.0` of
    the toolchain SDK (`sdk_version`), so "no version stated" means the newest,
    as it does for the format style; without `sdk_version` it is
    `>=3.0.0 <4.0.0`.

    Pubspec-reading lints fire on the harness unless this is a valid pubspec,
    so the `dart_analyze` aspect stages one for both its analyze and its fix
    action.

    Args:
      packages: List of DartPackageInfo (from `collect_packages`) — every
        package the staged `package_config.json` will carry.
      name: The pubspec's `name:` field. The default names the harness-level
        stub at the project root; per-package stubs pass the real package name
        so the analyzer attributes each staged file to its true package.
      sdk_version: The toolchain SDK's version (e.g. `3.11.0`); the constraint
        for a package that states no `language_version`. Empty for none.

    Returns:
      The pubspec file's contents, as a string.
    """
    sdk = ">=3.0.0 <4.0.0"
    parts = sdk_version.split(".")
    if len(parts) >= 2:
        sdk = "^%s.%s.0" % (parts[0], parts[1])
    for p in packages:
        if p.package_name == name and getattr(p, "language_version", ""):
            sdk = "^%s.0" % p.language_version
            break
    lines = ["name: %s" % name, "environment:", '  sdk: "%s"' % sdk]
    names = sorted([
        p.package_name
        for p in packages
        if p.package_name and p.package_name != name
    ])
    if names:
        lines.append("dependencies:")
        for dep in names:
            lines.append("  %s: any" % dep)
    return "\n".join(lines) + "\n"

def main_package_roots(packages):
    """Returns the main-repo package roots that receive a stub pubspec.

    One entry per distinct `lib_root`; when several package records share a
    root (the split-package case), the lexically-first name wins so the choice
    is deterministic. External (`../`-prefixed) packages are excluded — they
    live outside the staged project and are never analyzed.

    Args:
      packages: List of DartPackageInfo (from `collect_packages`).

    Returns:
      Sorted list of (lib_root, package_name) tuples.
    """
    seen = {}
    for pkg in packages:
        if pkg.lib_root.startswith("../") or not pkg.package_name:
            continue
        prev = seen.get(pkg.lib_root)
        if prev == None or pkg.package_name < prev:
            seen[pkg.lib_root] = pkg.package_name
    return sorted(seen.items())

def staged_pubspec_paths(packages):
    """Project-relative paths of the per-package stub pubspecs staging writes.

    The `dart_analyze` aspect composes its wrapper `analysis_options.yaml`
    before calling `stage_dart_project`, so the stub paths it must exclude are
    computed here, from the same dedupe rule staging uses, rather than
    returned by it.

    Args:
      packages: List of DartPackageInfo (from `collect_packages`).

    Returns:
      Sorted list of `src/...` path strings, one per stub pubspec.
    """
    return [
        ("src/%s/pubspec.yaml" % lib_root) if lib_root else "src/pubspec.yaml"
        for lib_root, _ in main_package_roots(packages)
    ]

def external_package_placement(ext_pkgs, ext_files_by_pkg):
    """Decides, for each external package, whether it is referenced in place or copied.

    A package is referenced in place when every one of its files sits under
    one exec-root directory, so its rootUri can name that directory and no
    file is copied.

    It is copied when its files sit under two or more directories. That
    happens to a `dart_library` from another Bazel module that mixes
    hand-written sources (`external/<repo>/lib/...`) with `dart_codegen`
    outputs (`bazel-out/<cfg>/bin/external/<repo>/lib/...`): no single
    directory holds the whole package, so no single rootUri can name it.
    Copying merges the two, as copy mode always does. Every file is checked,
    not only the first, because one file alone would reference such a package
    at whichever directory it happened to sit in.

    Args:
      ext_pkgs: List of the external DartPackageInfo providers.
      ext_files_by_pkg: Dict of package_name -> list of that package's Files
        (`short_path` and `path`), for the packages that have any.

    Returns:
      struct(
        roots: dict of package_name -> exec-root-relative directory, for the
          packages referenced in place,
        copied: list of package_names to copy, in `ext_files_by_pkg` order,
      )
    """
    by_name = {p.package_name: p for p in ext_pkgs}
    roots = {}
    copied = []
    for pkg_name, files in ext_files_by_pkg.items():
        lib_root = by_name[pkg_name].lib_root
        dirs = {package_exec_root(f, lib_root): True for f in files}
        if len(dirs) == 1:
            roots[pkg_name] = dirs.keys()[0]
        else:
            copied.append(pkg_name)
    return struct(roots = roots, copied = copied)

def stage_dart_project(ctx, packages, all_srcs, extra_proj_files = {}, name = None, sdk_version = "", copy_external = True):
    """Stages packages and sources into a hermetic Dart project layout.

    Args:
      ctx: The rule context (must carry `COPY_TO_DIRECTORY_TOOLCHAINS`).
      packages: List of DartPackageInfo (from `collect_packages`).
      all_srcs: Flat list of Files to stage (the rule's own srcs/main plus the
        flattened transitive closure).
      extra_proj_files: Dict of `<filename> -> content string` written as
        declared files directly under `<name>.proj/` (e.g. a `pubspec.yaml`
        stub for `dart analyze`).
      name: Prefix for the staged paths; defaults to the target's name. An
        aspect passes its own, so it cannot collide with the target's outputs.
      sdk_version: The toolchain SDK's version, the staged SDK constraint of a
        package that states no `language_version`. Empty for the old default.
      copy_external: True copies each external package into its own
        `<name>.extpkgs/<pkg>` tree. False points the config at each external
        package's real directory in the exec root and declares its files as
        `inputs`, copying nothing, except a package whose files span more than
        one directory (see `external_package_placement`), which is copied as
        in True. Use False wherever the staged project is read from the exec
        root by an action, and True where it is read from runfiles (see the
        module docstring).

    Returns:
      struct(
        proj_path: exec path of the `<name>.proj` directory,
        src_tree: the `src` tree artifact File,
        package_config: the written package_config File,
        proj_files: dict of `extra_proj_files` name -> the File written,
        inputs: list of Files to add to the consuming action's inputs: the
          copied trees, the config, and the files of the packages referenced
          in place (which the config names directly).
      )
    """
    name = name or ctx.label.name

    ext_pkgs = [p for p in packages if p.lib_root.startswith("../")]
    main_files = []
    ext_files_by_pkg = {}
    ext_index = package_index(ext_pkgs)
    for f in all_srcs:
        if f.short_path.startswith("../"):
            # External files matching no package have no package: URI to
            # serve; nothing can resolve them from the staged project.
            owner = package_for_index(f.short_path, ext_index)
            if owner != None:
                ext_files_by_pkg.setdefault(owner, []).append(f)
        else:
            main_files.append(f)

    # One stub pubspec per main-repo package root (see the module docstring
    # for why lints need it). The stubs cannot be declared at their final
    # paths — `<name>.proj/src` is a tree artifact, and Bazel rejects declared
    # files under a declared directory — so each is written to a sibling
    # `.pkgstubs` staging spot and mapped into place by the same
    # `copy_to_directory` that assembles the tree.
    stub_files = []
    replace_prefixes = {}
    for lib_root, package_name in main_package_roots(packages):
        stub = ctx.actions.declare_file("{}.pkgstubs/{}/pubspec.yaml".format(
            name,
            mangle_package_dir(lib_root) if lib_root else "_root",
        ))
        ctx.actions.write(stub, pubspec_stub(packages, name = package_name, sdk_version = sdk_version))

        # Key on the stub's workspace-relative directory: with `root_paths=[]`
        # that is exactly the path prefix it would keep inside the tree.
        replace_prefixes[stub.short_path.rsplit("/", 1)[0]] = lib_root
        stub_files.append(stub)

    src_tree = assemble_source_dir(
        ctx,
        name + ".proj/src",
        main_files + stub_files,
        # Keep workspace-relative paths: each package's lib_root must be a
        # real directory under src/ for the rootUris above to hold.
        root_paths = [],
        replace_prefixes = replace_prefixes,
    )

    inputs = [src_tree]
    ext_staged = {pkg_name: True for pkg_name in ext_files_by_pkg}

    # Referenced in place where possible; copied otherwise (see the helper).
    if copy_external:
        ext_roots = {}
        copied = list(ext_files_by_pkg.keys())
    else:
        placement = external_package_placement(ext_pkgs, ext_files_by_pkg)
        ext_roots = placement.roots
        copied = placement.copied

    for pkg_name, files in ext_files_by_pkg.items():
        if pkg_name in copied:
            tree = assemble_source_dir(
                ctx,
                "{}.extpkgs/{}".format(name, mangle_package_dir(pkg_name)),
                files,
                root_paths = [],
                include_external_repositories = ["*"],
            )
            inputs.append(tree)
        else:
            inputs.extend(files)

    package_config = ctx.actions.declare_file(name + ".proj/.dart_tool/package_config.json")
    ctx.actions.write(
        output = package_config,
        content = staged_package_config_content(
            packages,
            ext_staged,
            name,
            ext_roots = ext_roots,
            config_dir = package_config.dirname,
        ),
    )
    inputs.append(package_config)

    proj_files = {}
    for filename, content in extra_proj_files.items():
        extra = ctx.actions.declare_file(name + ".proj/" + filename)
        ctx.actions.write(output = extra, content = content)
        inputs.append(extra)
        proj_files[filename] = extra

    return struct(
        proj_path = src_tree.dirname,
        src_tree = src_tree,
        package_config = package_config,
        proj_files = proj_files,
        inputs = inputs,
    )
