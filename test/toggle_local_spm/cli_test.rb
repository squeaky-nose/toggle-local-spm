# frozen_string_literal: true

require_relative "../test_helper"

class ToggleLocalSpmCLITest < Minitest::Test
  include ToggleLocalSpmTestHelpers

  def test_class_method_run_delegates_to_a_new_instance
    ran = false
    fake = Object.new
    fake.define_singleton_method(:run) { ran = true }

    ToggleLocalSpm::CLI.stub :new, fake do
      ToggleLocalSpm::CLI.run(["some-package"])
    end

    assert ran, "CLI.run(argv) should build an instance and call #run on it"
  end

  def test_swaps_a_direct_dependency_to_local_and_back
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))
      before = read_pbxproj(repo)

      out, = run_cli(["sample-package"], root: repo, input: "n\nn\n")

      assert_match(/Swapped 'sample-package' to local checkout at \.\.\/sample-package/, out)
      pbxproj = read_pbxproj(repo)
      assert_includes pbxproj, "isa = XCLocalSwiftPackageReference"
      assert_includes pbxproj, 'relativePath = "../sample-package"'
      refute_includes pbxproj, 'XCRemoteSwiftPackageReference "sample-package"'

      state = read_state(repo)
      assert_equal "direct", state["sample-package"]["type"]
      assert_equal "git@github.com:example/sample-package.git", state["sample-package"]["repositoryURL"]

      run_cli(["sample-package"], root: repo, input: "n\nn\n")

      assert_equal before, read_pbxproj(repo)
      assert_equal "direct", read_state(repo)["sample-package"]["type"], "record must be retained after swapping back"
    end
  end

  def test_indirect_dependency_is_discovered_added_and_removed
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/direct-package.git", package_version: "1.0.0")
      write_resolved_file(repo, pins: [
        { "identity" => "transitive-package", "kind" => "remoteSourceControl",
          "location" => "git@github.com:example/transitive-package.git",
          "state" => { "revision" => "abc123", "version" => "2.0.0" } }
      ])
      make_local_checkout(File.join(root, "transitive-package"))

      out, = run_cli(["transitive-package"], root: repo, input: "n\nn\n")

      assert_match(/Added local override for 'transitive-package'/, out)
      pbxproj = read_pbxproj(repo)
      assert_includes pbxproj, 'relativePath = "../transitive-package"'
      # no product dependency was created for the override — it's unlinked
      refute_match(/isa = XCSwiftPackageProductDependency;\s*\n\s*package = \S+ \/\* XCLocalSwiftPackageReference "transitive-package"/, pbxproj)

      state = read_state(repo)
      assert_equal "indirect", state["transitive-package"]["type"]
      assert_equal({ "kind" => "exactVersion", "version" => "2.0.0" }, state["transitive-package"]["requirement"])

      out2, = run_cli(["transitive-package"], root: repo, input: "n\nn\n")

      assert_match(/Removed local override for 'transitive-package'/, out2)
      refute_includes read_pbxproj(repo), "transitive-package"
      assert_equal "indirect", read_state(repo)["transitive-package"]["type"], "record must be retained after removing the override"
    end
  end

  def test_respects_hand_edited_local_path
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      moved = File.join(root, "moved-checkout")
      make_local_checkout(moved)
      File.write(File.join(repo, "spm-local-overrides.json"), JSON.generate("sample-package" => { "localPath" => moved }))

      run_cli(["sample-package"], root: repo, input: "n\nn\n")

      assert_includes read_pbxproj(repo), 'relativePath = "../moved-checkout"'
    end
  end

  def test_toggles_multiple_packages_in_one_run
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      project_path = build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      project = Xcodeproj::Project.open(project_path)
      second_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
      second_ref.repositoryURL = "git@github.com:example/other-package.git"
      second_ref.requirement = { "kind" => "exactVersion", "version" => "3.0.0" }
      project.root_object.package_references << second_ref
      project.save

      make_local_checkout(File.join(root, "sample-package"))
      make_local_checkout(File.join(root, "other-package"))

      run_cli(%w[sample-package other-package], root: repo, input: "n\nn\n")

      pbxproj = read_pbxproj(repo)
      assert_includes pbxproj, 'relativePath = "../sample-package"'
      assert_includes pbxproj, 'relativePath = "../other-package"'
    end
  end

  def test_errors_clearly_when_local_checkout_is_missing
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")

      error = assert_raises(ToggleLocalSpm::Error) do
        run_cli(["sample-package"], root: repo, input: "n\nn\n")
      end
      assert_match(/expected a local checkout with a Package\.swift/, error.message)
    end
  end

  def test_errors_clearly_for_unknown_package_name
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")

      error = assert_raises(ToggleLocalSpm::Error) do
        run_cli(["totally-unknown"], root: repo, input: "n\nn\n")
      end
      assert_match(/no package dependency named 'totally-unknown'/, error.message)
      assert_match(/sample-package/, error.message)
    end
  end

  def test_errors_when_no_xcodeproj_found
    Dir.mktmpdir do |root|
      error = assert_raises(ToggleLocalSpm::Error) { run_cli([], root: root, input: "") }
      assert_match(/no \.xcodeproj found/, error.message)
    end
  end

  def test_load_state_raises_clear_error_on_invalid_json
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      File.write(File.join(repo, "spm-local-overrides.json"), "{ not valid json")

      error = assert_raises(ToggleLocalSpm::Error) do
        run_cli(["sample-package"], root: repo, input: "n\nn\n")
      end
      assert_match(/could not parse/, error.message)
      assert_match(/spm-local-overrides\.json/, error.message)
    end
  end

  def test_gracefully_ignores_unparseable_package_resolved
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      resolved_path = File.join(repo, "Sample.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
      FileUtils.mkdir_p(File.dirname(resolved_path))
      File.write(resolved_path, "{ not valid json")
      make_local_checkout(File.join(root, "sample-package"))

      # Should not raise — an unparseable Package.resolved just means no
      # indirect candidates are discoverable, not a hard failure.
      out, = run_cli(["sample-package"], root: repo, input: "n\nn\n")
      assert_match(/Swapped 'sample-package' to local checkout/, out)
    end
  end

  def test_discovers_indirect_dependencies_via_top_level_workspace_when_present
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/direct-package.git", package_version: "1.0.0")
      FileUtils.mkdir_p(File.join(repo, "Sample.xcworkspace"))

      resolved_path = File.join(repo, "Sample.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
      FileUtils.mkdir_p(File.dirname(resolved_path))
      File.write(resolved_path, JSON.pretty_generate("pins" => [
        { "identity" => "transitive-package", "kind" => "remoteSourceControl",
          "location" => "git@github.com:example/transitive-package.git",
          "state" => { "revision" => "abc123", "version" => "2.0.0" } }
      ]))
      make_local_checkout(File.join(root, "transitive-package"))

      out, = run_cli(["transitive-package"], root: repo, input: "n\nn\n")

      assert_match(/Added local override for 'transitive-package'/, out)
    end
  end

  def test_interactive_selection_accepts_a_single_number
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      out, = run_cli([], root: repo, input: "1\nn\nn\n")

      assert_match(/Swapped 'sample-package' to local checkout/, out)
    end
  end

  def test_interactive_selection_accepts_multiple_numbers
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      project_path = build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      project = Xcodeproj::Project.open(project_path)
      second_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
      second_ref.repositoryURL = "git@github.com:example/other-package.git"
      second_ref.requirement = { "kind" => "exactVersion", "version" => "3.0.0" }
      project.root_object.package_references << second_ref
      project.save

      make_local_checkout(File.join(root, "sample-package"))
      make_local_checkout(File.join(root, "other-package"))

      out, = run_cli([], root: repo, input: "1 2\nn\nn\n")

      assert_match(/Swapped 'sample-package' to local checkout/, out)
      assert_match(/Swapped 'other-package' to local checkout/, out)
    end
  end

  def test_interactive_selection_rejects_blank_input
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")

      error = assert_raises(ToggleLocalSpm::Error) { run_cli([], root: repo, input: "\n") }
      assert_match(/invalid selection/, error.message)
    end
  end

  def test_interactive_selection_rejects_non_numeric_input
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")

      error = assert_raises(ToggleLocalSpm::Error) { run_cli([], root: repo, input: "abc\n") }
      assert_match(/invalid selection 'abc'/, error.message)
    end
  end

  def test_interactive_selection_rejects_out_of_range_number
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")

      error = assert_raises(ToggleLocalSpm::Error) { run_cli([], root: repo, input: "99\n") }
      assert_match(/invalid selection '99'/, error.message)
    end
  end

  def test_swap_local_to_remote_errors_without_a_state_record
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      project_path = File.join(repo, "Sample.xcodeproj")
      project = Xcodeproj::Project.new(project_path)
      project.new_target(:application, "Sample", :ios)
      # A local ref created by hand (not by this tool), so there's no
      # spm-local-overrides.json entry to restore a remote reference from.
      local_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
      local_ref.relative_path = "../sample-package"
      project.root_object.package_references << local_ref
      project.save

      error = assert_raises(ToggleLocalSpm::Error) do
        run_cli(["sample-package"], root: repo, input: "n\nn\n")
      end
      assert_match(/no recorded remote reference for 'sample-package'/, error.message)
    end
  end

  def test_xcode_running_option_1_waits_for_user_to_close_it
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      out, = run_cli(["sample-package"], root: repo, input: "1\n\nn\nn\n", xcode_running: [true, false])

      assert_match(/Xcode is currently running/, out)
      refute_match(/still appears to be running/, out)
    end
  end

  def test_xcode_running_option_1_warns_if_still_running_after_continuing
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      _, err = run_cli(["sample-package"], root: repo, input: "1\n\nn\nn\n", xcode_running: true)

      assert_match(/warning: Xcode still appears to be running\./, err)
    end
  end

  def test_xcode_running_option_2_proceeds_without_closing
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      out, = run_cli(["sample-package"], root: repo, input: "2\nn\nn\n", xcode_running: true)

      assert_match(/Swapped 'sample-package' to local checkout/, out)
    end
  end

  def test_xcode_running_option_3_quits_xcode_for_you
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      commands = []
      run_command = lambda do |*args|
        commands << args
        true
      end

      run_cli(["sample-package"], root: repo, input: "3\nn\nn\n", xcode_running: [true, false], run_command: run_command)

      assert_includes commands, ["osascript", "-e", 'tell application "Xcode" to quit']
    end
  end

  def test_xcode_running_option_3_warns_if_still_running_after_quit_attempt
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      _, err = run_cli(["sample-package"], root: repo, input: "3\nn\nn\n", xcode_running: true)

      assert_match(/warning: Xcode still appears to be running \(it may be waiting/, err)
    end
  end

  def test_xcode_running_rejects_invalid_selection
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")

      error = assert_raises(ToggleLocalSpm::Error) do
        run_cli(["sample-package"], root: repo, input: "9\n", xcode_running: true)
      end
      assert_match(/invalid selection/, error.message)
    end
  end

  def test_resolve_prompt_warns_when_resolution_fails
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      _, err = run_cli(["sample-package"], root: repo, input: "y\nn\n", run_command: ->(*_a) { false })

      assert_match(/warning: automatic package resolution failed/, err)
    end
  end

  def test_resolve_prompt_warns_when_xcodebuild_is_missing
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      run_command = ->(*_a) { raise Errno::ENOENT }
      _, err = run_cli(["sample-package"], root: repo, input: "y\nn\n", run_command: run_command)

      assert_match(/warning: xcodebuild not found on PATH/, err)
    end
  end

  def test_open_in_xcode_warns_on_failure
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      _, err = run_cli(["sample-package"], root: repo, input: "n\ny\n", run_command: ->(*_a) { false })

      assert_match(/warning: could not open/, err)
    end
  end

  def test_open_in_xcode_opens_the_xcodeproj_when_no_workspace_exists
    Dir.mktmpdir do |root|
      repo = File.join(root, "app")
      Dir.mkdir(repo)
      build_fixture_project(repo, package_url: "git@github.com:example/sample-package.git", package_version: "1.0.0")
      make_local_checkout(File.join(root, "sample-package"))

      commands = []
      run_command = lambda do |*args|
        commands << args
        true
      end

      run_cli(["sample-package"], root: repo, input: "n\ny\n", run_command: run_command)

      opened = commands.find { |c| c.first == "open" }
      assert opened
      assert_match(/Sample\.xcodeproj\z/, opened.last)
    end
  end
end
