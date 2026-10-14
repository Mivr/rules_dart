"""Unit tests for the stub pubspec in project_staging.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:project_staging.bzl", "external_package_placement", "pubspec_stub", "staged_package_config_content")
load(":small_suite.bzl", "small_unittest_suite")

def _pkg(name, language_version = ""):
    return struct(package_name = name, language_version = language_version)

def _sdk_from_language_version_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5"), _pkg("other")]
    asserts.true(env, 'sdk: "^3.5.0"' in pubspec_stub(pkgs, name = "app"))
    return unittest.end(env)

def _sdk_default_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5"), _pkg("other")]
    asserts.true(env, 'sdk: ">=3.0.0 <4.0.0"' in pubspec_stub(pkgs, name = "other"))
    asserts.true(env, 'sdk: ">=3.0.0 <4.0.0"' in pubspec_stub(pkgs))
    return unittest.end(env)

def _sdk_toolchain_version_test_impl(ctx):
    env = unittest.begin(ctx)
    pkgs = [_pkg("app", "3.5"), _pkg("other")]
    asserts.true(env, 'sdk: "^3.11.0"' in pubspec_stub(pkgs, name = "other", sdk_version = "3.11.2"))
    asserts.true(env, 'sdk: "^3.11.0"' in pubspec_stub(pkgs, sdk_version = "3.11.2"))
    asserts.true(env, 'sdk: "^3.5.0"' in pubspec_stub(pkgs, name = "app", sdk_version = "3.11.2"))
    return unittest.end(env)

def _dpkg(name, lib_root):
    return struct(package_name = name, lib_root = lib_root, language_version = "")

def _file(short_path, path):
    return struct(short_path = short_path, path = path)

def _config_fixture():
    """A main package and two pub packages, one of them under a repo's `<sub>`.

    Returns the packages and each external package's files. `baz` has no files
    in the project, so neither mode points at it.
    """
    packages = [
        _dpkg("app", "packages/app"),
        _dpkg("foo", "../foo"),
        _dpkg("bar", "../repo/sub"),
        _dpkg("baz", "../baz"),
    ]
    ext_files = {
        "foo": [_file("../foo/lib/foo.dart", "external/foo/lib/foo.dart")],
        "bar": [
            _file("../repo/sub/lib/bar.dart", "external/repo/sub/lib/bar.dart"),
            _file("../repo/sub/lib/data.json", "external/repo/sub/lib/data.json"),
        ],
    }
    return packages, ext_files

def _direct_root_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    packages, ext_files = _config_fixture()
    ext_pkgs = [p for p in packages if p.lib_root.startswith("../")]
    placement = external_package_placement(ext_pkgs, ext_files)
    ext_roots = placement.roots
    asserts.equals(env, [], placement.copied)

    # The roots are the exec-root directories the files sit in, sub path and all.
    asserts.equals(env, "external/foo", ext_roots["foo"])
    asserts.equals(env, "external/repo/sub", ext_roots["bar"])

    # The config lives in <proj>.proj/.dart_tool, six directories below the exec
    # root, so each rootUri climbs out of all six before naming the repository.
    config_dir = "bazel-out/k8-fastbuild/bin/pkg/demo.proj/.dart_tool"
    content = staged_package_config_content(
        packages,
        {"foo": True, "bar": True},
        "demo",
        ext_roots = ext_roots,
        config_dir = config_dir,
    )
    asserts.true(
        env,
        '{"name": "foo", "rootUri": "../../../../../../external/foo", "packageUri": "lib/"}' in content,
        content,
    )
    asserts.true(
        env,
        '{"name": "bar", "rootUri": "../../../../../../external/repo/sub", "packageUri": "lib/"}' in content,
        content,
    )

    # Main-repo packages are unchanged, and a package with no files is skipped.
    asserts.true(env, '"rootUri": "../src/packages/app"' in content, content)
    asserts.false(env, '"name": "baz"' in content, content)
    return unittest.end(env)

def _copy_root_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    packages, _ = _config_fixture()
    content = staged_package_config_content(
        packages,
        {"foo": True, "bar": True},
        "demo",
    )
    asserts.true(
        env,
        '{"name": "foo", "rootUri": "../../demo.extpkgs/foo", "packageUri": "lib/"}' in content,
        content,
    )
    asserts.true(
        env,
        '{"name": "bar", "rootUri": "../../demo.extpkgs/bar/sub", "packageUri": "lib/"}' in content,
        content,
    )
    asserts.false(env, '"name": "baz"' in content, content)
    return unittest.end(env)

def _mixed_package_test_impl(ctx):
    env = unittest.begin(ctx)
    packages = [_dpkg("foo", "../foo"), _dpkg("gen", "../repo")]
    ext_files = {
        "foo": [_file("../foo/lib/foo.dart", "external/foo/lib/foo.dart")],

        # One hand-written source and one `dart_codegen` output from the same
        # repository: the output sits under `bazel-out/`, so its directory is
        # not the one the source sits in.
        "gen": [
            _file("../repo/lib/hand.dart", "external/repo/lib/hand.dart"),
            _file("../repo/lib/gen.dart", "bazel-out/k8-fastbuild/bin/external/repo/lib/gen.dart"),
        ],
    }
    placement = external_package_placement(packages, ext_files)

    # `gen` is copied, not referenced at either directory; `foo` in the same
    # call is still referenced in place.
    asserts.equals(env, {"foo": "external/foo"}, placement.roots)
    asserts.equals(env, ["gen"], placement.copied)

    content = staged_package_config_content(
        packages,
        {"foo": True, "gen": True},
        "demo",
        ext_roots = placement.roots,
        config_dir = "bazel-out/k8-fastbuild/bin/pkg/demo.proj/.dart_tool",
    )
    asserts.true(
        env,
        '{"name": "foo", "rootUri": "../../../../../../external/foo", "packageUri": "lib/"}' in content,
        content,
    )
    asserts.true(
        env,
        '{"name": "gen", "rootUri": "../../demo.extpkgs/gen", "packageUri": "lib/"}' in content,
        content,
    )
    return unittest.end(env)

_t0_test = unittest.make(_sdk_from_language_version_test_impl)
_t1_test = unittest.make(_sdk_default_test_impl)
_t2_test = unittest.make(_sdk_toolchain_version_test_impl)
_t3_test = unittest.make(_direct_root_uri_test_impl)
_t4_test = unittest.make(_copy_root_uri_test_impl)
_t5_test = unittest.make(_mixed_package_test_impl)

def project_staging_test_suite(name):
    small_unittest_suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
