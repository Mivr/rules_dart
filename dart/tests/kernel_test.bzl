"""Unit tests for the pure decisions of modular kernel compilation.

`dart/private/dart_kernel.bzl` decides, without building anything, the URI each
source is compiled under, the package config a module names its packages with,
and whether an executable may compile modularly at all. Each of those is a
function of plain values, so each is tested here by calling it. The actions that
use them are exercised by the rules' own test targets.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//dart/private:common.bzl", "stable_path")
load(
    "//dart/private:dart_kernel.bzl",
    "duplicated_source",
    "entry_source_uri",
    "first_per_package",
    "kernel_package_config",
    "kernel_packages_consistent",
    "library_source_uri",
    "modular_kernel_eligible",
    "multi_root_uri",
)
load(":small_suite.bzl", "small_unittest_suite")

def _pkg(package_name, lib_root, language_version = ""):
    """A stand-in for `DartPackageInfo`, carrying the fields these functions read."""
    return struct(
        package_name = package_name,
        lib_root = lib_root,
        language_version = language_version,
    )

def _root_path_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "pkg/a", stable_path("pkg/a"), "a main-repo path is unchanged")
    asserts.equals(env, "external/repo", stable_path("../repo"), "an external repo maps under external/")
    asserts.equals(env, "external/repo/sub", stable_path("../repo/sub"), "an external sub-package maps under external/")
    asserts.equals(env, "", stable_path(""), "the root package stays empty")
    return unittest.end(env)

def _multi_root_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "org-dartlang-bazel:///pkg/a",
        multi_root_uri("pkg/a"),
        "a main-repo package root",
    )
    asserts.equals(
        env,
        "org-dartlang-bazel:///",
        multi_root_uri(""),
        "the root package is the bare scheme root",
    )
    asserts.equals(
        env,
        "org-dartlang-bazel:///external/repo",
        multi_root_uri("../repo"),
        "an external package root",
    )
    asserts.equals(
        env,
        "org-dartlang-bazel:///external/repo/sub",
        multi_root_uri("../repo/sub"),
        "an external sub-package root",
    )
    return unittest.end(env)

def _entry_source_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "org-dartlang-bazel:///pkg/test/x_test.dart",
        entry_source_uri("pkg/test/x_test.dart"),
        "a test in the main repo",
    )
    asserts.equals(
        env,
        "org-dartlang-bazel:///pkg/x.vm_test.dart",
        entry_source_uri("pkg/x.vm_test.dart"),
        "a generated bootstrap, which sits beside the test in the output tree",
    )
    asserts.equals(
        env,
        "org-dartlang-bazel:///external/repo/test/x_test.dart",
        entry_source_uri("../repo/test/x_test.dart"),
        "a test from an external repo",
    )
    return unittest.end(env)

def _library_source_uri_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        "package:a/src/x.dart",
        library_source_uri("a", "pkg/a", "pkg/a/lib/src/x.dart"),
        "a file under a package's lib/ is named by its package: path",
    )
    asserts.equals(
        env,
        "package:a/x.dart",
        library_source_uri("a", "", "lib/x.dart"),
        "the root package strips lib/ alone",
    )
    asserts.equals(
        env,
        "package:a/x.dart",
        library_source_uri("a", "../repo", "../repo/lib/x.dart"),
        "an external package strips its lib_root and lib/",
    )
    return unittest.end(env)

def _package_config_test_impl(ctx):
    env = unittest.begin(ctx)
    config = kernel_package_config([
        _pkg("a", "pkg/a", "3.9"),
        _pkg("root", ""),
        _pkg("ext", "../repo/sub"),
    ])
    expected = (
        "{\n" +
        '  "configVersion": 2,\n' +
        '  "packages": [\n' +
        '    {"name": "a", "rootUri": "org-dartlang-bazel:///pkg/a", "packageUri": "lib/", "languageVersion": "3.9"},\n' +
        '    {"name": "root", "rootUri": "org-dartlang-bazel:///", "packageUri": "lib/"},\n' +
        '    {"name": "ext", "rootUri": "org-dartlang-bazel:///external/repo/sub", "packageUri": "lib/"}\n' +
        "  ]\n" +
        "}\n"
    )
    asserts.equals(env, expected, config, "one entry per package, with its multi-root rootUri")
    return unittest.end(env)

def _packages_consistent_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(
        env,
        kernel_packages_consistent([_pkg("a", "pkg/a"), _pkg("a", "pkg/a"), _pkg("b", "pkg/b")]),
        "a name repeated at one root is one package",
    )
    asserts.false(
        env,
        kernel_packages_consistent([_pkg("a", "pkg/a"), _pkg("a", "other/a")]),
        "a name at two roots cannot be one rootUri",
    )
    asserts.false(
        env,
        kernel_packages_consistent([_pkg("a", ""), _pkg("b", "")]),
        "two root packages would share the bare scheme root",
    )
    asserts.true(
        env,
        kernel_packages_consistent([_pkg("a", ""), _pkg("b", "pkg/b")]),
        "one root package beside others is fine",
    )
    return unittest.end(env)

def _first_per_package_test_impl(ctx):
    env = unittest.begin(ctx)
    kept = first_per_package([_pkg("a", "pkg/a", "3.9"), _pkg("b", "pkg/b"), _pkg("a", "pkg/a", "")])
    asserts.equals(env, ["a", "b"], [p.package_name for p in kept], "one record per name, in order")
    asserts.equals(env, "3.9", kept[0].language_version, "the first record wins")
    return unittest.end(env)

def _duplicated_source_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "a.dart", duplicated_source(["a.dart", "b.dart", "a.dart"]), "a repeated path")
    asserts.equals(env, None, duplicated_source(["a.dart", "b.dart"]), "no repeat")
    asserts.equals(env, None, duplicated_source([]), "nothing to repeat")
    return unittest.end(env)

_ELIGIBLE = {
    "enabled": True,
    "kernel_mode": True,
    "dep_modular": True,
    "packages_consistent": True,
    "has_code_assets": False,
    "has_own_defines": False,
    "has_compile_flags": False,
    "has_duplicate_source": False,
    "same_sdk": True,
}

def _eligible_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, modular_kernel_eligible(**_ELIGIBLE), "every condition met")

    # Each override is a reason to fall back to whole-program compilation.
    fallbacks = {
        "flag is off": {"enabled": False},
        "not a kernel": {"kernel_mode": False},
        "a dependency is not modular": {"dep_modular": False},
        "the closure has a package at two roots": {"packages_consistent": False},
        "code assets are embedded": {"has_code_assets": True},
        "the test sets its own `defines`": {"has_own_defines": True},
        "dart_compile_flags are set": {"has_compile_flags": True},
        "a source is compiled twice": {"has_duplicate_source": True},
        "the exec and target SDKs differ": {"same_sdk": False},
    }
    for reason, override in fallbacks.items():
        kwargs = dict(_ELIGIBLE)
        kwargs.update(override)
        asserts.false(env, modular_kernel_eligible(**kwargs), reason)
    return unittest.end(env)

_root_path_test = unittest.make(_root_path_test_impl)
_multi_root_uri_test = unittest.make(_multi_root_uri_test_impl)
_entry_source_uri_test = unittest.make(_entry_source_uri_test_impl)
_library_source_uri_test = unittest.make(_library_source_uri_test_impl)
_package_config_test = unittest.make(_package_config_test_impl)
_packages_consistent_test = unittest.make(_packages_consistent_test_impl)
_first_per_package_test = unittest.make(_first_per_package_test_impl)
_duplicated_source_test = unittest.make(_duplicated_source_test_impl)
_eligible_test = unittest.make(_eligible_test_impl)

def kernel_test_suite(name):
    """Declares the modular kernel unit tests as one suite.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _root_path_test,
        _multi_root_uri_test,
        _entry_source_uri_test,
        _library_source_uri_test,
        _package_config_test,
        _packages_consistent_test,
        _first_per_package_test,
        _duplicated_source_test,
        _eligible_test,
    )
