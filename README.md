# toggle-local-spm

[![Tests](https://github.com/squeaky-nose/toggle-local-spm/actions/workflows/tests.yml/badge.svg)](https://github.com/squeaky-nose/toggle-local-spm/actions/workflows/tests.yml)
[![codecov](https://codecov.io/gh/squeaky-nose/toggle-local-spm/graph/badge.svg?token=0SUUH3UPIQ)](https://codecov.io/gh/squeaky-nose/toggle-local-spm)
[![Gem Version](https://badge.fury.io/rb/toggle-local-spm.svg)](https://rubygems.org/gems/toggle-local-spm)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A CLI that toggles Swift Package Manager dependencies in an Xcode project
between their remote (git) reference and a local checkout in a sibling
folder — useful when developing a package alongside the app that consumes
it. This works both for packages the project depends on directly, and for
packages only pulled in transitively (a dependency of one of the project's
own dependencies) — see **Direct vs. indirect dependencies** below.

Run it on a package and it swaps the remote reference for a local one. Run
it again on the same package and it swaps back to the original remote
reference. It edits `project.pbxproj` directly (via the [xcodeproj][xcodeproj]
gem) and, for a direct dependency, reuses the existing package reference's
object ID when swapping, so the diff it produces is minimal and easy to
review — only the swapped reference's `isa`/attributes change, nothing else
in the file churns.

[xcodeproj]: https://github.com/CocoaPods/Xcodeproj

## Requirements

- Run from the root of the Xcode project's repo — the directory containing
  the `.xcodeproj` (there must be exactly one there).
- The first time you swap a package to local, its checkout is expected to be
  an adjacent sibling directory, named to match the package's repo (e.g. if
  the project depends on `git@github.com:org/some-package.git`, this tool
  looks for `../some-package` containing a `Package.swift`). After that,
  where it looks is whatever `spm-local-overrides.json` says — see below.
- macOS with Xcode installed (`xcodebuild` is used to re-resolve
  `Package.resolved` after swapping).
- A `Package.resolved` that's already been generated at least once (needed to
  discover indirect dependencies — see below). If there isn't one yet, only
  direct dependencies are toggleable until one exists.

## Installation

Add this to the consuming project's `Gemfile`:

```ruby
gem "toggle-local-spm"
```

Then:

```bash
bundle install
```

(Pin a version range, e.g. `gem "toggle-local-spm", "~> 2.0"`, if you want
more control over upgrades — see [Releasing a new version](#releasing-a-new-version)
for how versions are cut.)

## Usage

From the root of the Xcode project's repo:

```bash
# Toggle one package by name (matched against its repo/folder name)
bundle exec toggle-local-spm some-package

# Toggle several packages in one go
bundle exec toggle-local-spm some-package another-package

# Or with no arguments, pick from an interactive menu of every package
# dependency in the project (space/comma-separated numbers for more than one)
bundle exec toggle-local-spm
```

The interactive menu lists every direct dependency (from the project itself)
and every indirect one (from `Package.resolved`) as a table, each tagged with
its type, current state, and whether it has a record in
`spm-local-overrides.json` (see below), e.g.:

```
  #  Package        Type        State     Managed
  1  my-shared-ios  🎯 direct    🌏 remote  ✅
  2  DeviceKit      🎯 direct    🌏 remote
  3  my-model-lib   🧩 indirect  🌏 remote
```

Each package toggles independently based on what's currently wired up in the
project: a package currently on its remote reference (or, for an indirect
dependency, not yet overridden at all) swaps to local; a package currently
on a local reference swaps back to remote.

Before touching `project.pbxproj`, if Xcode is currently running you'll be
asked how to handle it — Xcode holding the project open can silently
overwrite the file while this tool is editing it:

```
Xcode is currently running, which can overwrite project.pbxproj while it's being edited.
  1) I'll close it myself
  2) Do nothing, proceed anyway
  3) Close Xcode for me
```

Option 1 waits for you to close it and press Enter; option 3 quits Xcode for
you (a normal quit — Xcode will still prompt you to save anything unsaved).

After the swap(s), you'll be prompted:

```
Resolve package dependencies now? [Y/n]
```

Press enter (or `y`) to run `xcodebuild -resolvePackageDependencies` and
refresh `Package.resolved` immediately, or `n` to skip it and resolve later
yourself (e.g. via Xcode's **File > Packages > Resolve Package Versions**).
If resolution fails (no network, no SSH key for a private repo, etc.) it
prints a warning — the `project.pbxproj` swap itself has already succeeded
either way. Finally:

```
Open in Xcode now? [Y/n]
```

Press enter (or `y`) to open the project (the `.xcworkspace` if there is
one, otherwise the `.xcodeproj`) — handy for picking up right where the
"close Xcode for me" option above left off, with a freshly-resolved project.

## Direct vs. indirect dependencies

A **direct** dependency already has (or had) its own top-level entry in the
project's "Package Dependencies" list (`project.pbxproj`'s
`XCRemoteSwiftPackageReference`/`XCLocalSwiftPackageReference` entries).
Toggling one off always leaves a reference behind — swapped back to remote —
since the project genuinely, permanently depends on it.

An **indirect** dependency has no such entry — it's only known because it
shows up in `Package.resolved`, meaning some *other* dependency's own
`Package.swift` depends on it (e.g. `my-shared-ios` depending on
`my-model-lib`). Toggling one of these on doesn't edit that
other package's `Package.swift` at all. Instead it adds a brand-new,
*unlinked* local package reference directly to the project — not attached to
any target — purely so Xcode/SwiftPM's identity-based dependency resolution
overrides the transitive reference with the local checkout, wherever else in
the graph it's declared. Toggling it back off removes that reference
entirely, since it was never a real dependency of the project — it was only
ever an override anchor.

> [!NOTE]
> This relies on SwiftPM allowing two different sources (a remote pin from a
> transitive `Package.swift`, and a local override elsewhere in the same
> graph) to share one package identity, silently preferring the local one.
> This works today, but SwiftPM's own resolver logs it as a *"Conflicting
> identity"* warning and states plainly that **this will be escalated to an
> error in future versions of SwiftPM**. If a future Xcode/SwiftPM version
> makes this a hard error, indirect-dependency overrides via this tool will
> stop working and need a different approach (e.g. editing the declaring
> package's `Package.swift` directly).

## `spm-local-overrides.json`

The first time you swap any package to local, this tool creates
`spm-local-overrides.json` at the repo root. It's a permanent, per-developer
record of every package it has ever touched — created once and never
deleted, and entries are only ever added to or updated, never removed (even
after a package is swapped back to remote, or an indirect override is
removed). Whether a package is currently "on" (local) or "off" (remote) is
**not** read from this file — it's determined by inspecting the project
itself (is there a reference for it, and is it an
`XCRemoteSwiftPackageReference` or an `XCLocalSwiftPackageReference`?). This
file only ever supplies the *details* needed to perform a swap.

Each entry looks like:

```json
{
  "some-package": {
    "repositoryURL": "git@github.com:org/some-package.git",
    "requirement": { "kind": "exactVersion", "version": "1.2.3" },
    "localPath": "/Users/you/code/some-package",
    "type": "direct"
  }
}
```

- `repositoryURL` / `requirement` — the package's remote reference, captured
  automatically the first time it's swapped to local (from the project
  itself for a direct dependency, or from `Package.resolved` for an indirect
  one). Used to restore the exact same remote reference when swapping a
  direct dependency back; recorded for indirect dependencies too but not
  strictly needed to turn one off (that just removes the reference).
- `type` — `"direct"` or `"indirect"`, set automatically the first time a
  package is toggled (see above). Missing `type` on an older entry is
  treated as `"direct"`.
- `localPath` — where the local checkout lives. Set automatically to the
  default sibling folder the first time you swap a package to local. **Edit
  this by hand** if your checkout lives somewhere else, or under a different
  name — the next swap-to-local for that package will use whatever path is
  here instead of guessing a sibling folder.

This file is specific to your machine (it records absolute local paths), so
it should stay out of version control — add `spm-local-overrides.json` to
the consuming project's `.gitignore`.

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can
also run `bin/console` for an interactive prompt that will allow you to
experiment.

To install this gem onto your local machine, run `bundle exec rake install`.

### Tests and coverage

`bundle exec rake test` runs the suite (also the default Rake task) and
writes:

- A coverage report to `coverage/` via [SimpleCov][simplecov] —
  `coverage/index.html` for a local human-readable view,
  `coverage/coverage.json` for Codecov's coverage reporting to ingest.
- JUnit XML test results to `test/reports/` via [minitest-reporters][minitest-reporters].

CI ([.github/workflows/tests.yml](.github/workflows/tests.yml)) runs the
same suite on every push to `main` and every PR, then:

- Uploads coverage to Codecov via `codecov/codecov-action`.
- Publishes the JUnit XML as GitHub check annotations and a job summary
  via [mikepenz/action-junit-report][action-junit-report] (with
  `detailed_summary`/`include_passed` so every individual test case shows,
  not just failures) — per-test pass/fail shows up directly on the
  commit/PR's checks and in the workflow run's summary tab, no external
  service needed. (We also tried reporting test results to Codecov's Test
  Analytics via `report_type: test_results`; every upload consistently
  logged success but never appeared anywhere in Codecov's UI even after
  ruling out XML format, plan/visibility gating, and branch-config
  mismatches — looks like a gap on their end, not something fixable from
  this workflow. Filed with Codecov support; worth revisiting later.)
- Uploads both reports as a downloadable build artifact
  (`test-reports`), for whenever a run needs deeper debugging.

Both the coverage upload and the check-annotations step run even if the
test step itself fails (`if: ${{ !cancelled() }}`), since a failing run is
exactly what you want visibility into.

Codecov needs one manual, one-time setup step that isn't in this diff: add
the repo at [codecov.io](https://codecov.io) (sign in with GitHub, enable
the org/repo), then copy its **upload token** and add it as a repo secret
named `CODECOV_TOKEN` (Settings → Secrets and variables → Actions).

[simplecov]: https://github.com/simplecov-ruby/simplecov
[minitest-reporters]: https://github.com/minitest-reporters/minitest-reporters
[action-junit-report]: https://github.com/mikepenz/action-junit-report

## Releasing a new version

The [Release workflow](.github/workflows/release.yml) automates the whole
process, including publishing to RubyGems.org:

1. Go to the repo's **Actions** tab → **Release** → **Run workflow**.
2. Enter the new version as bare `x.y.z` (no `v` prefix — the workflow adds
   it when constructing the tag, e.g. entering `2.3.0` produces `v2.3.0`).
3. Run it.

On a fresh runner, the workflow then:

- Validates the input matches `x.y.z` and that the tag doesn't already exist
  (refusing to overwrite an existing release).
- Bumps `lib/toggle_local_spm/version.rb`.
- Regenerates `Gemfile.lock` (`bundle install`) so its `PATH` section
  matches the new version — CI's `bundler-cache: true` step in
  [tests.yml](.github/workflows/tests.yml) installs in frozen mode and will
  hard-fail if this drifts.
- Runs `bundle exec rake test` as a safety gate — nothing is committed,
  tagged, published, or released if the suite fails.
- Commits as "Bump version to X.Y.Z", tags it `vX.Y.Z`, and pushes both to
  `main`.
- Creates a GitHub Release for the tag via `gh release create --generate-notes`.
- Publishes the gem to [RubyGems.org](https://rubygems.org/gems/toggle-local-spm)
  via [Trusted Publishing][trusted-publishing] (OIDC — no stored API key).

Consumers just run `bundle update toggle-local-spm` to pick up a new
version.

[trusted-publishing]: https://guides.rubygems.org/trusted-publishing/

### One-time setup

RubyGems.org Trusted Publishing needs a "pending trusted publisher"
registered once, before the *first* release, at
[rubygems.org/profile/oidc/pending_trusted_publishers](https://rubygems.org/profile/oidc/pending_trusted_publishers):

- Gem name: `toggle-local-spm`
- Repository owner / name: `squeaky-nose` / `toggle-local-spm`
- Workflow filename: `release.yml`
- Environment: `release`

After the first successful publish, RubyGems.org converts this from
"pending" to a normal trusted publisher automatically — no further setup
needed for later releases.

**Manual fallback** (e.g. the workflow is unavailable, or `main`'s branch
protection blocks the workflow's token from pushing):

1. Bump the version in `lib/toggle_local_spm/version.rb`.
2. Run `bundle install` to regenerate `Gemfile.lock`.
3. Run `bundle exec rake test`.
4. Commit as "Bump version to X.Y.Z", then `git tag vX.Y.Z`.
5. `git push origin main && git push origin vX.Y.Z`.
6. Create a release from the pushed tag: `gh release create vX.Y.Z --generate-notes`
   (or via the GitHub UI's Releases page).
7. Publish the gem: `gem build toggle-local-spm.gemspec && gem push toggle-local-spm-X.Y.Z.gem`
   (needs a RubyGems.org API key with push access on your machine, since
   Trusted Publishing only works from the configured GitHub Actions workflow).

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/squeaky-nose/toggle-local-spm.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
