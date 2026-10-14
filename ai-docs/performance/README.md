# Performance review (started 2026-10-14)

A review of how fast and how hermetic rules_dart's build, test and analysis
actions are, and a series of changes landing one by one on `main`, each verified
and benchmarked before it lands.

Start here, then read in this order:

1. [`plan.md`](plan.md): every item, its status, and its measured effect.
2. [`decisions.md`](decisions.md): decisions log. Who decided what, and why.
3. [`findings.md`](findings.md): measurements and facts established along the
   way (SDK behaviour, tool limits). These are why the designs look the way they do.
4. [`in-flight.md`](in-flight.md): work that exists but is not on `main` yet.
5. [`for-rules-flutter.md`](for-rules-flutter.md): what changed, or will
   change, for rule sets built on rules_dart.
6. [`harness/`](harness/): the benchmark and verification harness, and
   [`results/`](results/), its raw output.

## Process every change follows

1. An agent implements it in its own git worktree, branched from `main`.
2. The reviewing agent reads the diff, then runs: the unit tests
   (`//dart/tests/... //dart/private/tools/... //dart/runfiles/...`), the e2e
   workspaces the change touches, the CI red-path checks from
   `.github/workflows/ci.yaml` for the area, and the benchmark suite, against
   current `main`, back to back.
3. Only then is it fast-forwarded onto `main`, with a `Changelog:` trailer per
   `AGENTS.md`.

Two checks were added to that list after something slipped through:

- **Lockfile**: any change to a `.bzl` file the `pub` or `dart` module
  extension loads changes its recorded `bzlTransitiveDigest`. Every
  `MODULE.bazel.lock` must then be refreshed, or `--lockfile_mode=error` fails.
  See `decisions.md`, 2026-10-14, "lockfile regression".
- **Reproducibility**: every new or changed build output must be byte-identical
  across two clean builds. See `findings.md`, "Reproducibility audit".
