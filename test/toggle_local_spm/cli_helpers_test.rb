# frozen_string_literal: true

require_relative "../test_helper"

class ToggleLocalSpmCLIHelpersTest < Minitest::Test
  def setup
    @cli = ToggleLocalSpm::CLI.new([], root: Dir.pwd)
    @project = Xcodeproj::Project.new("/tmp/unused-for-tests.xcodeproj")
  end

  def test_ref_name_strips_dot_git_and_preserves_case_for_remote_refs
    ref = @project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    ref.repositoryURL = "git@github.com:example/DeviceKit.git"
    assert_equal "DeviceKit", @cli.send(:ref_name, ref)
  end

  def test_ref_name_uses_basename_for_local_refs
    ref = @project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    ref.relative_path = "../some-package"
    assert_equal "some-package", @cli.send(:ref_name, ref)
  end

  def test_requirement_from_resolved_state_prefers_version
    requirement = @cli.send(:requirement_from_resolved_state, "version" => "1.2.3", "revision" => "abc")
    assert_equal({ "kind" => "exactVersion", "version" => "1.2.3" }, requirement)
  end

  def test_requirement_from_resolved_state_falls_back_to_branch
    requirement = @cli.send(:requirement_from_resolved_state, "branch" => "main", "revision" => "abc")
    assert_equal({ "kind" => "branch", "branch" => "main" }, requirement)
  end

  def test_requirement_from_resolved_state_falls_back_to_revision
    requirement = @cli.send(:requirement_from_resolved_state, "revision" => "abc123")
    assert_equal({ "kind" => "revision", "revision" => "abc123" }, requirement)
  end

  def test_detect_scheme_prefers_scheme_matching_workspace_name
    Dir.mktmpdir do |root|
      xcodeproj = Pathname.new(root) + "Sample.xcodeproj"
      FileUtils.mkdir_p(xcodeproj + "xcshareddata/xcschemes")
      FileUtils.touch(xcodeproj + "xcshareddata/xcschemes/Other.xcscheme")
      FileUtils.touch(xcodeproj + "xcshareddata/xcschemes/Sample.xcscheme")
      workspace = Pathname.new(root) + "Sample.xcworkspace"

      assert_equal "Sample", @cli.send(:detect_scheme, xcodeproj, workspace)
    end
  end

  def test_detect_scheme_falls_back_to_first_scheme_alphabetically
    Dir.mktmpdir do |root|
      xcodeproj = Pathname.new(root) + "Sample.xcodeproj"
      FileUtils.mkdir_p(xcodeproj + "xcshareddata/xcschemes")
      FileUtils.touch(xcodeproj + "xcshareddata/xcschemes/Beta.xcscheme")
      FileUtils.touch(xcodeproj + "xcshareddata/xcschemes/Alpha.xcscheme")
      workspace = Pathname.new(root) + "Different.xcworkspace"

      assert_equal "Alpha", @cli.send(:detect_scheme, xcodeproj, workspace)
    end
  end

  def test_managed_label_is_blank_when_untracked
    remote_ref = @project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    candidate = ToggleLocalSpm::CLI::Candidate.new("some-package", remote_ref, "direct", nil, false)
    assert_equal "", @cli.send(:managed_label_for, candidate)
  end

  def test_managed_label_is_set_when_tracked_and_local
    local_ref = @project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
    candidate = ToggleLocalSpm::CLI::Candidate.new("some-package", local_ref, "direct", nil, true)
    assert_equal "✅", @cli.send(:managed_label_for, candidate)
  end

  def test_managed_label_is_found_when_tracked_but_remote
    remote_ref = @project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
    candidate = ToggleLocalSpm::CLI::Candidate.new("some-package", remote_ref, "direct", nil, true)
    assert_equal "📁", @cli.send(:managed_label_for, candidate)
  end

  def test_detect_scheme_returns_nil_when_no_schemes_exist
    Dir.mktmpdir do |root|
      xcodeproj = Pathname.new(root) + "Sample.xcodeproj"
      FileUtils.mkdir_p(xcodeproj)
      workspace = Pathname.new(root) + "Sample.xcworkspace"

      assert_nil @cli.send(:detect_scheme, xcodeproj, workspace)
    end
  end

  def test_resolve_target_args_uses_project_when_no_workspace_exists
    Dir.mktmpdir do |root|
      xcodeproj = Pathname.new(root) + "Sample.xcodeproj"
      FileUtils.mkdir_p(xcodeproj)
      cli = ToggleLocalSpm::CLI.new([], root: root)

      assert_equal ["-project", xcodeproj.to_s], cli.send(:resolve_target_args, xcodeproj)
    end
  end

  def test_resolve_target_args_falls_back_to_project_when_workspace_has_no_scheme
    Dir.mktmpdir do |root|
      xcodeproj = Pathname.new(root) + "Sample.xcodeproj"
      FileUtils.mkdir_p(xcodeproj)
      FileUtils.mkdir_p(Pathname.new(root) + "Sample.xcworkspace")
      cli = ToggleLocalSpm::CLI.new([], root: root)

      assert_equal ["-project", xcodeproj.to_s], cli.send(:resolve_target_args, xcodeproj)
    end
  end

  def test_resolve_target_args_uses_workspace_and_scheme_when_both_exist
    Dir.mktmpdir do |root|
      xcodeproj = Pathname.new(root) + "Sample.xcodeproj"
      FileUtils.mkdir_p(xcodeproj + "xcshareddata/xcschemes")
      FileUtils.touch(xcodeproj + "xcshareddata/xcschemes/Sample.xcscheme")
      workspace = Pathname.new(root) + "Sample.xcworkspace"
      FileUtils.mkdir_p(workspace)
      cli = ToggleLocalSpm::CLI.new([], root: root)

      assert_equal ["-workspace", workspace.to_s, "-scheme", "Sample"], cli.send(:resolve_target_args, xcodeproj)
    end
  end

  def test_run_command_wraps_kernel_system
    assert @cli.send(:run_command, "true")
    refute @cli.send(:run_command, "false")
  end

  def test_xcode_running_reflects_a_real_process_check
    # Not asserting a specific value (Xcode may or may not actually be
    # running on whatever machine executes this) — just that the real
    # pgrep-backed implementation runs and returns a system()-shaped result.
    assert_includes [true, false, nil], @cli.send(:xcode_running?)
  end

  def test_xcode_quit_timeout_and_poll_interval_defaults
    assert_equal 10, @cli.send(:xcode_quit_timeout)
    assert_equal 0.5, @cli.send(:xcode_quit_poll_interval)
  end
end
