"""Tests which packages a target's analyzer summaries cover.

`dart_analyze`'s summary mode analyzes a target from summaries only when every
package in its closure is covered (`_summaries_ready`). A package is covered
when a summary covers it. An opaque `srcs_dir` library has no summary, so its
package must be left uncovered; otherwise a dependent would be analyzed against
a summary that does not exist.

The aspect runs with `//dart:analyzer_summaries` on, which `config_settings`
sets for the target under test.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//dart/private:dart_analyzer_summary.bzl", "DartAnalyzerSummaryInfo", "dart_analyzer_summary")

def _summary_packages_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    covered = [k.split("|")[0] for k in target[DartAnalyzerSummaryInfo].packages.to_list()]
    for name in ctx.attr.expect_covered:
        asserts.true(
            env,
            name in covered,
            "%s: package %s is not covered; covered: %s" % (target.label, name, covered),
        )
    for name in ctx.attr.expect_uncovered:
        asserts.false(
            env,
            name in covered,
            "%s: package %s is covered, but it has no summary; covered: %s" % (target.label, name, covered),
        )
    return analysistest.end(env)

summary_packages_test = analysistest.make(
    _summary_packages_test_impl,
    attrs = {
        "expect_covered": attr.string_list(),
        "expect_uncovered": attr.string_list(),
    },
    config_settings = {str(Label("//dart:analyzer_summaries")): True},
    extra_target_under_test_aspects = [dart_analyzer_summary],
)
