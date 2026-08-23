# frozen_string_literal: true

# Coverage tracking must start before the library code it's measuring is
# required, so this has to be the very first thing in the file.
require "simplecov"
require "simplecov_json_formatter"
SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new(
  [SimpleCov::Formatter::HTMLFormatter, SimpleCov::Formatter::JSONFormatter]
)
SimpleCov.start do
  add_filter "/test/"
end

require "minitest/autorun"
require "minitest/reporters"
Minitest::Reporters.use! [
  Minitest::Reporters::DefaultReporter.new,
  Minitest::Reporters::JUnitReporter.new
]

require "stringio"
require "tmpdir"
require "fileutils"
require "json"
require "toggle_local_spm"

module ToggleLocalSpmTestHelpers
  # Builds a minimal, synthetic Xcode project (no real project data) inside
  # `repo_dir`, with one remote package dependency linked to a target.
  # Returns the .xcodeproj path.
  def build_fixture_project(repo_dir, project_name: "Sample", package_url:, package_version:)
    project_path = File.join(repo_dir, "#{project_name}.xcodeproj")
    project = Xcodeproj::Project.new(project_path)
    target = project.new_target(:application, project_name, :ios)

    remote_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    remote_ref.repositoryURL = package_url
    remote_ref.requirement = { "kind" => "exactVersion", "version" => package_version }
    project.root_object.package_references << remote_ref

    dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    dep.package = remote_ref
    dep.product_name = File.basename(package_url, ".git")
    target.package_product_dependencies << dep

    project.save
    project_path
  end

  # Writes a Package.resolved (in the location toggle-local-spm reads from
  # for a project with no separate .xcworkspace) with the given pins.
  def write_resolved_file(repo_dir, project_name: "Sample", pins: [])
    path = File.join(repo_dir, "#{project_name}.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate("originHash" => "test", "pins" => pins, "version" => 3))
    path
  end

  def make_local_checkout(dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "Package.swift"), "// swift-tools-version: 5.9\n")
  end

  def read_pbxproj(repo_dir, project_name: "Sample")
    File.read(File.join(repo_dir, "#{project_name}.xcodeproj", "project.pbxproj"))
  end

  def read_state(repo_dir)
    JSON.parse(File.read(File.join(repo_dir, "spm-local-overrides.json")))
  end

  # Runs the CLI with scripted stdin answers, capturing stdout/stderr so test
  # output stays clean, and never shells out for real:
  #
  # - `xcode_running`: either a fixed true/false, or an Array of successive
  #   return values (popped one per call, last value repeats once
  #   exhausted) — lets a test simulate "Xcode was open, then wasn't".
  #   Defaults to false so most tests don't need to think about this at all.
  # - `run_command`: a lambda receiving the same args `system(...)` would
  #   (e.g. `->(*args) { true }`), for the small number of tests that care
  #   what external command got run and with what result.
  def run_cli(args, root:, input: "", xcode_running: false, run_command: ->(*) { true })
    old_stdin = $stdin
    $stdin = StringIO.new(input)
    cli = ToggleLocalSpm::CLI.new(args, root: root)

    xcode_running_values = Array(xcode_running).dup
    cli.define_singleton_method(:xcode_running?) do
      xcode_running_values.size > 1 ? xcode_running_values.shift : xcode_running_values.first
    end
    cli.define_singleton_method(:run_command) { |*a| run_command.call(*a) }
    # Real defaults (10s timeout, 0.5s polling) would make a test where
    # Xcode never "quits" actually wait 10 seconds — shrink both so that
    # scenario resolves near-instantly instead.
    cli.define_singleton_method(:xcode_quit_timeout) { 0.05 }
    cli.define_singleton_method(:xcode_quit_poll_interval) { 0.01 }

    capture_io { cli.run }
  ensure
    $stdin = old_stdin
  end
end
