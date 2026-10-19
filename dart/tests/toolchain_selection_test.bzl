"""Unit tests for the Dart toolchain version selection in the `dart` extension."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//dart/private:toolchain_selection.bzl", "select_toolchain_version")
load(":small_suite.bzl", "small_unittest_suite")

def _req(version, is_root = False):
    return struct(version = version, is_root = is_root)

def _single_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.13.4", is_root = True)])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _latest_wins_numerically_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.9.0"), _req("3.13.4"), _req("3.10.1")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_older_than_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.12.2", is_root = True), _req("3.13.4")])
    asserts.equals(env, "3.12.2", selection.version)
    asserts.true(env, selection.note != None)
    return unittest.end(env)

def _root_newer_than_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.13.4", is_root = True), _req("3.12.2")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_equal_to_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.13.4", is_root = True), _req("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _no_root_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.12.2"), _req("3.13.4")])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _several_root_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("dart", [_req("3.12.2", is_root = True), _req("3.13.4", is_root = True)])
    asserts.equals(env, "3.13.4", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _several_toolchain_names_test_impl(ctx):
    env = unittest.begin(ctx)
    selection_dart = select_toolchain_version("dart", [_req("3.12.2", is_root = True)])
    selection_foo = select_toolchain_version("foo", [_req("3.10.0")])
    asserts.equals(env, "3.12.2", selection_dart.version)
    asserts.equals(env, "3.10.0", selection_foo.version)
    return unittest.end(env)

_single_request_test = unittest.make(_single_request_test_impl)
_latest_wins_numerically_test = unittest.make(_latest_wins_numerically_test_impl)
_root_older_than_dep_test = unittest.make(_root_older_than_dep_test_impl)
_root_newer_than_dep_test = unittest.make(_root_newer_than_dep_test_impl)
_root_equal_to_dep_test = unittest.make(_root_equal_to_dep_test_impl)
_no_root_request_test = unittest.make(_no_root_request_test_impl)
_several_root_tags_test = unittest.make(_several_root_tags_test_impl)
_several_toolchain_names_test = unittest.make(_several_toolchain_names_test_impl)

def toolchain_selection_test_suite(name):
    small_unittest_suite(
        name,
        _single_request_test,
        _latest_wins_numerically_test,
        _root_older_than_dep_test,
        _root_newer_than_dep_test,
        _root_equal_to_dep_test,
        _no_root_request_test,
        _several_root_tags_test,
        _several_toolchain_names_test,
    )