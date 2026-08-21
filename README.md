# toggle-local-spm

A CLI that toggles a Swift Package Manager dependency in an Xcode project
between its remote (git) reference and a local checkout in an adjacent
sibling folder — useful when developing a package alongside the app that
consumes it.

Run it once on a package and it swaps the remote reference for a local one.
Run it again on the same package and it swaps back to the original remote
reference. It edits `project.pbxproj` directly (via the [xcodeproj][xcodeproj]
gem) and reuses the existing package reference's object ID when swapping, so
the diff it produces is minimal and easy to review — only the swapped
reference's `isa`/attributes change, nothing else in the file churns.

[xcodeproj]: https://github.com/CocoaPods/Xcodeproj

## Requirements

- Run from the root of the Xcode project's repo — the directory containing
  the `.xcodeproj` (there must be exactly one there).
- The local checkout of the dependency you want to swap to must be an
  adjacent sibling directory, named to match the package's repo (e.g. if the
  project depends on `git@github.com:org/some-package.git`, this tool looks
  for `../some-package` containing a `Package.swift`).
- macOS with Xcode installed (`xcodebuild` is used to re-resolve
  `Package.resolved` after swapping).

## Installation

This gem isn't published to RubyGems.org — install it straight from GitHub.
Add this to the consuming project's `Gemfile`:

```ruby
gem "toggle-local-spm", git: "https://github.com/sushant40/toggle-local-spm.git", tag: "v0.1.0"
```

Then:

```bash
bundle install
```

## Usage

From the root of the Xcode project's repo:

```bash
# Toggle a specific package by name (matched against its repo/folder name)
bundle exec toggle-local-spm some-package

# Or with no argument, pick from an interactive menu of every package
# dependency in the project
bundle exec toggle-local-spm
```

The first time you swap a package to local, the tool records its original
remote reference (URL + version requirement) in a `.spm-local-overrides.json`
file at the repo root, so it knows what to restore on the next run. Add that
file to the consuming project's `.gitignore` — it's per-developer, local
state and shouldn't be committed.

After swapping, the tool runs `xcodebuild -resolvePackageDependencies` to
refresh `Package.resolved`. If that fails (no network, no SSH key for a
private repo, etc.) it prints a warning — the `project.pbxproj` swap itself
still succeeded, and you can finish resolving manually in Xcode via
**File > Packages > Resolve Package Versions**.

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
https://github.com/sushant40/toggle-local-spm.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
