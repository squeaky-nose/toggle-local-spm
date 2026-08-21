# frozen_string_literal: true

require_relative "lib/toggle_local_spm/version"

Gem::Specification.new do |spec|
  spec.name = "toggle-local-spm"
  spec.version = ToggleLocalSpm::VERSION
  spec.authors = ["Sushant Verma"]
  spec.email = ["sushant.40@gmail.com"]

  spec.summary = "Toggle an Xcode project's Swift Package dependency between its remote reference and a local sibling checkout."
  spec.description = "A CLI that swaps a Swift Package Manager dependency in an .xcodeproj between its " \
                      "remote (git) reference and a local checkout in an adjacent sibling folder, and back " \
                      "again, without churning the underlying pbxproj object IDs."
  spec.homepage = "https://github.com/sushant40/toggle-local-spm"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  # This gem is distributed via its git repo (see README), not pushed to rubygems.org.
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "xcodeproj", ">= 1.19", "< 2.0"
end
