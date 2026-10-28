"""Tests for a package's runfiles-only files and the `data` attribute.

`data` on `dart_library`/`dart_package_member` is deliberately not `resources`
and not `srcs`: its files ride runfiles, reach the binaries and tests that
depend on the package, and never enter an action. These tests pin all three
halves — `DefaultInfo` placement, the `DartInfo` records a consumer reads
without walking runfiles, and the absence of the files from every action's
inputs — plus the generated pub-spoke glob that supplies the default.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//dart:providers.bzl", "DartInfo")

# This suite asserts the generated BUILD shape through the public re-export,
# which is what rules_flutter consumes; it never reaches into pub/private.
load("//dart/pub:pub_lock_package.bzl", "make_dart_library_build_content")
load("//dart/tests:small_suite.bzl", "small_unittest_suite")

def _short_paths(files):
    """The sorted `short_path`s of a file list.

    Args:
      files: The `File`s to name.

    Returns:
      A sorted list of strings.
    """
    return sorted([f.short_path for f in files])

def _assert_runfiles_only(env, target, expected_files, package_files):
    """Asserts package files are in runfiles but not `DefaultInfo.files`.

    Args:
      env: The analysis-test environment.
      target: The target under test.
      expected_files: Source `short_path`s that must be in `files` and runfiles.
      package_files: The runtime `File`s that must be in runfiles only.
    """
    files = _short_paths(target[DefaultInfo].files.to_list())
    runfiles = _short_paths(target[DefaultInfo].default_runfiles.files.to_list())
    for path in _short_paths(package_files):
        asserts.true(env, path in runfiles, "%s missing from runfiles" % path)
        asserts.false(env, path in files, "%s leaked into DefaultInfo.files" % path)
    for path in expected_files:
        asserts.true(env, path in files, "%s missing from DefaultInfo.files" % path)
        asserts.true(env, path in runfiles, "%s missing from runfiles" % path)

def _assert_no_action_inputs(env, target, package_files):
    """Asserts no action of the target lists a package file as an input.

    Args:
      env: The analysis-test environment.
      target: The target under test; its actions are read from the env.
      package_files: The runtime `File`s that must not be action inputs.
    """
    blocked = {f.path: True for f in package_files}
    for action in analysistest.target_actions(env):
        # The runfiles tree's whole job is to list the runfiles as inputs;
        # every other action must never see one of these files.
        if action.mnemonic == "RunfilesTree":
            continue
        for f in action.inputs.to_list():
            asserts.false(
                env,
                f.path in blocked,
                "%s action %s lists package file %s as an input" % (
                    action.mnemonic,
                    target.label,
                    f.path,
                ),
            )

def _assert_package_records(env, info, package_name, lib_root_suffix, package_files):
    """Asserts the own and transitive package-file fields carry the record.

    Args:
      env: The analysis-test environment.
      info: The target's `DartInfo`.
      package_name: The package name the record must state.
      lib_root_suffix: The suffix the record's `lib_root` must end with.
      package_files: The `File`s the record and the transitive depset must
        carry.
    """
    records = [
        record
        for record in info.package_files.to_list()
        if record.package_name == package_name
    ]
    asserts.equals(env, 1, len(records), "expected one %s record" % package_name)
    if len(records) != 1:
        return
    record = records[0]
    asserts.true(
        env,
        record.lib_root.endswith(lib_root_suffix),
        "record lib_root %s does not end with %s" % (record.lib_root, lib_root_suffix),
    )
    expected = _short_paths(package_files)
    asserts.equals(env, expected, _short_paths(record.files))
    asserts.equals(
        env,
        expected,
        _short_paths(info.transitive_package_files.to_list()),
    )

def _library_data_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    package_files = ctx.files.package_files

    _assert_runfiles_only(env, target, ["dart/tests/package_files_fixture/lib/pkg.dart"], package_files)
    _assert_package_records(
        env,
        target[DartInfo],
        "package_files_fixture",
        "dart/tests/package_files_fixture",
        package_files,
    )
    _assert_no_action_inputs(env, target, package_files)
    return analysistest.end(env)

library_data_test = analysistest.make(
    _library_data_test_impl,
    attrs = {"package_files": attr.label_list(allow_files = True)},
)

def _member_data_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    package_files = ctx.files.package_files

    _assert_runfiles_only(env, target, ["dart/tests/package_files_fixture/lib/member.dart"], package_files)
    asserts.false(env, DartInfo in target, "a member must not become a legal deps entry")
    _assert_no_action_inputs(env, target, package_files)
    return analysistest.end(env)

member_data_test = analysistest.make(
    _member_data_test_impl,
    attrs = {"package_files": attr.label_list(allow_files = True)},
)

def _merged_data_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    package_files = ctx.files.package_files

    _assert_runfiles_only(env, target, ["dart/tests/package_files_fixture/lib/member.dart"], package_files)
    _assert_package_records(
        env,
        target[DartInfo],
        "package_files_member",
        "dart/tests/package_files_fixture",
        package_files,
    )
    _assert_no_action_inputs(env, target, package_files)
    return analysistest.end(env)

merged_data_test = analysistest.make(
    _merged_data_test_impl,
    attrs = {"package_files": attr.label_list(allow_files = True)},
)

def _binary_data_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    package_files = ctx.files.package_files

    # The binary's own output is not a library source, so every expected file
    # here is a dependency package file: runfiles must carry it.
    _assert_runfiles_only(env, target, [], package_files)
    _assert_no_action_inputs(env, target, package_files)
    return analysistest.end(env)

binary_data_test = analysistest.make(
    _binary_data_test_impl,
    attrs = {"package_files": attr.label_list(allow_files = True)},
)

def _dart_in_data_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "is a Dart source in `data`")
    return analysistest.end(env)

dart_in_data_test = analysistest.make(
    _dart_in_data_test_impl,
    expect_failure = True,
)

def _default_package_files_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_dart_library_build_content(
        name = "example",
        deps = [],
        language_version = "3.0",
    )
    asserts.true(
        env,
        'data = glob(\n        ["pubspec.yaml", "LICENSE*"],\n' in content,
        "the default package_files glob is missing: %s" % content,
    )
    asserts.true(
        env,
        'exclude = ["lib/**", "BUILD*", "WORKSPACE*"],' in content,
        "the default package_files excludes are missing: %s" % content,
    )
    asserts.true(
        env,
        "        allow_empty = True,\n    ),\n" in content,
        "the package_files glob must allow an empty package: %s" % content,
    )
    asserts.false(env, '"test/**"' in content, "the default must not walk test/: %s" % content)
    return unittest.end(env)

def _opt_in_package_files_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_dart_library_build_content(
        name = "example",
        deps = [],
        language_version = "3.0",
        package_files = ["assets/**", "fonts/**"],
    )
    asserts.true(
        env,
        'data = glob(\n        ["assets/**", "fonts/**"],\n' in content,
        "the opt-in package_files glob is missing: %s" % content,
    )
    asserts.true(
        env,
        'exclude = ["lib/**", "BUILD*", "WORKSPACE*"],' in content,
        "the opt-in glob keeps the standard excludes: %s" % content,
    )
    return unittest.end(env)

def _opt_out_package_files_test_impl(ctx):
    env = unittest.begin(ctx)
    content = make_dart_library_build_content(
        name = "example",
        deps = [],
        language_version = "3.0",
        package_files = [],
    )
    asserts.false(env, "data = glob(" in content, "an empty package_files list must emit no data: %s" % content)
    return unittest.end(env)

_default_package_files_test = unittest.make(_default_package_files_test_impl)
_opt_in_package_files_test = unittest.make(_opt_in_package_files_test_impl)
_opt_out_package_files_test = unittest.make(_opt_out_package_files_test_impl)

def _dart_info_defaults_test_impl(ctx):
    """A producer that predates the package-file fields still builds.

    rules_flutter constructs `DartInfo` directly, with the fields it knew
    when it was written, so the two package-file fields are absent on that
    record. A reader that wants them must read through `getattr` with an empty
    default — the same shape `collect_code_asset_files` uses — rather than
    assume the field is always present.

    Args:
      ctx: The unit-test context.
    """
    env = unittest.begin(ctx)
    info = DartInfo(
        package_name = "old_producer",
        lib_root = "",
        owned_packages = [],
        transitive_srcs = depset(),
        transitive_resources = depset(),
        transitive_packages = depset(),
        transitive_code_asset_files = depset(),
    )
    asserts.equals(
        env,
        [],
        getattr(info, "package_files", depset()).to_list(),
        "package_files must read empty through getattr",
    )
    asserts.equals(
        env,
        [],
        getattr(info, "transitive_package_files", depset()).to_list(),
        "transitive_package_files must read empty through getattr",
    )

    # A partial record keeps its old shape: a field the producer never stated
    # stays absent, not empty.
    partial = DartInfo(transitive_packages = depset())
    asserts.false(env, hasattr(partial, "owned_packages"), "an omitted legacy field must stay absent")
    asserts.false(env, hasattr(partial, "package_files"), "an omitted package_files field must stay absent")
    asserts.equals(
        env,
        [],
        getattr(partial, "package_files", depset()).to_list(),
        "a bare producer reads empty package_files through getattr",
    )

    # A producer that does state the new fields sets both.
    record = struct(package_name = "producer", lib_root = "", files = ())
    stated = DartInfo(
        package_files = depset([record]),
        transitive_package_files = depset(),
    )
    asserts.equals(env, [record], stated.package_files.to_list(), "a stated package_files record must be kept")
    return unittest.end(env)

_dart_info_defaults_test = unittest.make(_dart_info_defaults_test_impl)

def package_files_content_test_suite(name):
    """Declares the generated-build-content tests for `package_files`.

    Args:
      name: Name of the generated `test_suite`.
    """
    small_unittest_suite(
        name,
        _dart_info_defaults_test,
        _default_package_files_test,
        _opt_in_package_files_test,
        _opt_out_package_files_test,
    )
