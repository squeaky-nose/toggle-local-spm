# toggle-local-spm

A CLI that toggles Swift Package Manager dependencies in an Xcode project
between their remote (git) reference and a local checkout in a sibling
folder — useful when developing a package alongside the app that consumes
it.

Run it on a package and it swaps the remote reference for a local one. Run
it again on the same package and it swaps back to the original remote
reference. It edits `project.pbxproj` directly (via the [xcodeproj][xcodeproj]
gem) and reuses the existing package reference's object ID when swapping, so
the diff it produces is minimal and easy to review — only the swapped
reference's `isa`/attributes change, nothing else in the file churns.

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

## Installation

This gem isn't published to RubyGems.org — install it straight from GitHub.
Add this to the consuming project's `Gemfile`:

```ruby
gem "toggle-local-spm", git: "https://github.com/squeaky-nose/toggle-local-spm.git", tag: "v0.1.0"
```

Then:

```bash
bundle install
```

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

Each package toggles independently based on what's currently wired up in the
project: a package currently on its remote reference swaps to local; a
package currently on a local reference swaps back to remote. After the
swap(s), you'll be prompted:

```
Resolve package dependencies now? [Y/n]
```

Press enter (or `y`) to run `xcodebuild -resolvePackageDependencies` and
refresh `Package.resolved` immediately, or `n` to skip it and resolve later
yourself (e.g. via Xcode's **File > Packages > Resolve Package Versions**).
If resolution fails (no network, no SSH key for a private repo, etc.) it
prints a warning — the `project.pbxproj` swap itself has already succeeded
either way.

## `spm-local-overrides.json`

The first time you swap any package to local, this tool creates
`spm-local-overrides.json` at the repo root. It's a permanent, per-developer
record of every package it has ever touched — created once and never
deleted, and entries are only ever added to or updated, never removed (even
after a package is swapped back to remote). Whether a package is currently
"on" (local) or "off" (remote) is **not** read from this file — it's
determined by inspecting the project itself (is the package's reference an
`XCRemoteSwiftPackageReference` or an `XCLocalSwiftPackageReference`?). This
file only ever supplies the *details* needed to perform a swap.

Each entry looks like:

```json
{
  "some-package": {
    "repositoryURL": "git@github.com:org/some-package.git",
    "requirement": { "kind": "exactVersion", "version": "1.2.3" },
    "localPath": "/Users/you/code/some-package"
  }
}
```

- `repositoryURL` / `requirement` — the package's remote reference, captured
  automatically the first time it's swapped to local. Used to restore the
  exact same remote reference when swapping back.
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

## Releasing a new version

This gem is distributed via git, not rubygems.org, so releases are just
tags:

1. Bump the version in `lib/toggle_local_spm/version.rb`.
2. Commit, then tag it: `git tag v0.2.0 && git push origin main --tags`.
3. Consumers bump the `tag:` in their `Gemfile` and run `bundle update toggle-local-spm`.

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/squeaky-nose/toggle-local-spm.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
