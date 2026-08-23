# frozen_string_literal: true

require "xcodeproj"
require "json"
require "pathname"

module ToggleLocalSpm
  # Toggles one or more Swift Package Manager dependencies between their
  # remote (git) reference and a local checkout. Run again on the same
  # package to swap back to the original remote reference. Afterwards,
  # optionally runs `xcodebuild -resolvePackageDependencies` so
  # Package.resolved is updated to match (requires network access and, for
  # private repos, a working SSH key).
  #
  # Run from the root of the Xcode project's repo (the directory containing
  # the .xcodeproj). A `spm-local-overrides.json` file is kept at the repo
  # root as a permanent record of each package's remote reference and local
  # checkout path (see README).
  #
  # Packages come in two flavors:
  # - "direct": already has (or had) a top-level XCRemoteSwiftPackageReference/
  #   XCLocalSwiftPackageReference entry in project.pbxproj. Toggling off
  #   always leaves a reference behind (swapped back to remote) since the
  #   project genuinely depends on it.
  # - "indirect": only known via Package.resolved — a transitive dependency
  #   of one of the project's own direct dependencies (e.g. a package
  #   declared in another package's own Package.swift), with no top-level
  #   reference of its own. Toggling one of these on adds a brand-new,
  #   unlinked local reference (no product/target linkage) purely so
  #   SwiftPM's identity-based graph resolution overrides the transitive
  #   pin with the local checkout; toggling off removes that reference
  #   entirely, since it was never a real project dependency.
  #
  # Which of these two states a package is in is recorded as "type" in
  # spm-local-overrides.json. Whether it's currently local or remote is
  # always read from the live project (an existing ref's isa, or its
  # absence for a not-yet-toggled indirect package) — never from the state
  # file or from Package.resolved, which can lag behind.
  class CLI
    RemoteRef = Xcodeproj::Project::Object::XCRemoteSwiftPackageReference
    LocalRef = Xcodeproj::Project::Object::XCLocalSwiftPackageReference
    ProductDependency = Xcodeproj::Project::Object::XCSwiftPackageProductDependency

    Candidate = Struct.new(:name, :ref, :type, :resolved_entry, :managed) do
      def local?
        ref.is_a?(LocalRef)
      end
    end

    TYPE_LABELS = { "direct" => "🎯 direct", "indirect" => "🧩 indirect" }.freeze
    STATE_LABELS = { local: "📁 local", remote: "🌏 remote" }.freeze

    def self.run(argv)
      new(argv).run
    end

    def initialize(argv, root: Dir.pwd)
      @package_names = argv
      @root = Pathname.new(root).expand_path
      @state_file = @root + "spm-local-overrides.json"
    end

    def run
      xcodeproj_path = find_xcodeproj_path
      project = Xcodeproj::Project.open(xcodeproj_path)
      state = load_state

      candidates = build_candidates(project, xcodeproj_path, state)
      abort_with("no Swift package dependencies found") if candidates.empty?

      selected = select_candidates(candidates)

      check_xcode_running

      selected.each { |candidate| toggle(project, xcodeproj_path, candidate, state) }

      save_state(state)
      project.save

      resolve_package_dependencies(xcodeproj_path) if prompt_resolve?
      open_in_xcode(xcodeproj_path) if prompt_open_in_xcode?

      puts "Done."
    end

    private

    def abort_with(message)
      raise Error, message
    end

    def find_xcodeproj_path
      candidates = Dir.glob(@root + "*.xcodeproj")
      abort_with("no .xcodeproj found in #{@root}") if candidates.empty?
      abort_with("multiple .xcodeproj found in #{@root}, expected one: #{candidates.join(", ")}") if candidates.size > 1
      Pathname.new(candidates.first)
    end

    def find_workspace_path
      candidates = Dir.glob(@root + "*.xcworkspace")
      candidates.first && Pathname.new(candidates.first)
    end

    def load_state
      return {} unless @state_file.exist?

      JSON.parse(@state_file.read)
    rescue JSON::ParserError => e
      abort_with("could not parse #{@state_file}: #{e.message}")
    end

    # The state file is a permanent record: it is created on first use and
    # never deleted, and entries are only ever added to or updated, never
    # removed — even after a package is swapped back to remote (or an
    # indirect override is removed). This lets a developer hand-edit a
    # package's "localPath" without losing the recorded repositoryURL/
    # requirement, and preserves "type" so a package's direct/indirect
    # classification is stable across runs.
    def save_state(state)
      @state_file.write(JSON.pretty_generate(state) + "\n")
    end

    def ref_name(ref)
      case ref
      when RemoteRef
        File.basename(ref.repositoryURL.to_s, ".git")
      when LocalRef
        File.basename(ref.relative_path.to_s)
      end
    end

    def product_dependencies_for(project, ref)
      project.objects.select { |o| o.is_a?(ProductDependency) && o.package == ref }
    end

    # Replaces `old_ref` with a new package reference of `new_ref_class`, reusing
    # old_ref's UUID and its position in packageReferences. This keeps every
    # `package = <uuid>` line in XCSwiftPackageProductDependency untouched (only
    # the referenced object's isa/attributes change), so toggling produces a
    # minimal, easy-to-review diff instead of churning UUIDs.
    def replace_ref(project, old_ref, new_ref_class)
      deps = product_dependencies_for(project, old_ref)
      package_references = project.root_object.package_references
      index = package_references.index(old_ref)
      uuid = old_ref.uuid

      # Detach old_ref from every referrer first so its UUID is freed from
      # objects_by_uuid before the new object claims that same UUID below.
      deps.each { |dep| dep.package = nil }
      package_references.delete(old_ref)

      new_ref = new_ref_class.new(project, uuid)
      new_ref.initialize_defaults
      yield new_ref

      package_references.insert(index, new_ref)
      deps.each { |dep| dep.package = new_ref }

      new_ref
    end

    # --- Candidate discovery ---------------------------------------------

    def build_candidates(project, xcodeproj_path, state)
      refs = project.root_object.package_references.select { |r| r.is_a?(RemoteRef) || r.is_a?(LocalRef) }
      direct = refs.map do |ref|
        name = ref_name(ref)
        type = state.dig(name, "type") || "direct"
        Candidate.new(name, ref, type, nil, state.key?(name))
      end

      resolved = load_resolved_packages(xcodeproj_path)
      indirect = resolved.reject { |name, _| direct.any? { |c| c.name.casecmp(name).zero? } }
                          .map { |name, info| Candidate.new(name, nil, "indirect", info, state.key?(name)) }

      direct + indirect
    end

    def resolved_file_path(xcodeproj_path)
      workspace = find_workspace_path
      if workspace
        workspace + "xcshareddata/swiftpm/Package.resolved"
      else
        xcodeproj_path + "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
      end
    end

    def load_resolved_packages(xcodeproj_path)
      path = resolved_file_path(xcodeproj_path)
      return {} unless path.exist?

      json = JSON.parse(path.read)
      pins = json["pins"] || json.dig("object", "pins") || []
      pins.each_with_object({}) do |pin, acc|
        location = pin["location"] || pin["repositoryURL"]
        next unless location

        name = File.basename(location, ".git")
        acc[name] = { "repositoryURL" => location, "requirement" => requirement_from_resolved_state(pin["state"] || {}) }
      end
    rescue JSON::ParserError
      {}
    end

    def requirement_from_resolved_state(resolved_state)
      if resolved_state["version"]
        { "kind" => "exactVersion", "version" => resolved_state["version"] }
      elsif resolved_state["branch"]
        { "kind" => "branch", "branch" => resolved_state["branch"] }
      elsif resolved_state["revision"]
        { "kind" => "revision", "revision" => resolved_state["revision"] }
      end
    end

    # --- Selection ----------------------------------------------------------

    def find_candidate(candidates, wanted)
      match = candidates.find { |c| c.name.casecmp(wanted).zero? }
      return match if match

      names = candidates.map(&:name).sort
      abort_with("no package dependency named '#{wanted}'. Available: #{names.join(", ")}")
    end

    def select_candidates(candidates)
      return @package_names.map { |wanted| find_candidate(candidates, wanted) }.uniq if @package_names.any?

      select_candidates_interactively(candidates)
    end

    def select_candidates_interactively(candidates)
      puts "Select package dependencies to toggle (e.g. 1, or 1 3):"
      puts

      index_width = candidates.size.to_s.length
      name_width = candidates.map { |c| c.name.length }.max
      type_width = TYPE_LABELS.values.map(&:length).max
      state_width = STATE_LABELS.values.map(&:length).max

      puts "  #{"#".rjust(index_width)}  #{"Package".ljust(name_width)}  #{"Type".ljust(type_width)}  " \
           "#{"State".ljust(state_width)}  Managed"
      candidates.each_with_index do |c, i|
        type_label = TYPE_LABELS.fetch(c.type, c.type).ljust(type_width)
        state_label = STATE_LABELS[c.local? ? :local : :remote].ljust(state_width)
        managed_label = c.managed ? "✅" : ""
        puts "  #{(i + 1).to_s.rjust(index_width)}  #{c.name.ljust(name_width)}  #{type_label}  #{state_label}  #{managed_label}"
      end

      print "\n> "
      choice = $stdin.gets&.strip
      abort_with("invalid selection") if choice.nil? || choice.empty?

      tokens = choice.split(/[\s,]+/)
      abort_with("invalid selection '#{choice}'") unless tokens.all? { |t| t.match?(/\A\d+\z/) }

      tokens.map(&:to_i).map do |n|
        index = n - 1
        abort_with("invalid selection '#{n}'") unless index.between?(0, candidates.size - 1)
        candidates[index]
      end.uniq
    end

    # --- Toggling -------------------------------------------------------

    def toggle(project, xcodeproj_path, candidate, state)
      if candidate.local?
        if candidate.type == "indirect"
          remove_indirect_ref(project, candidate)
        else
          swap_local_to_remote(project, xcodeproj_path, candidate.ref, state)
        end
      elsif candidate.ref.nil?
        add_indirect_local_ref(project, xcodeproj_path, candidate, state)
      else
        swap_remote_to_local(project, xcodeproj_path, candidate.ref, state)
      end
    end

    def resolve_local_dir(entry, name)
      local_dir = entry["localPath"] ? Pathname.new(entry["localPath"]).expand_path(@root) : (@root.parent + name)
      unless local_dir.directory? && (local_dir + "Package.swift").file?
        abort_with("expected a local checkout with a Package.swift at #{local_dir} " \
                   "(set or fix \"localPath\" for '#{name}' in #{@state_file} if it lives elsewhere)")
      end
      local_dir
    end

    def swap_remote_to_local(project, xcodeproj_path, ref, state)
      name = ref_name(ref)
      entry = state[name] || {}
      local_dir = resolve_local_dir(entry, name)
      relative_path = local_dir.relative_path_from(xcodeproj_path.dirname).to_s

      state[name] = entry.merge(
        "repositoryURL" => ref.repositoryURL,
        "requirement" => ref.requirement,
        "localPath" => local_dir.to_s,
        "type" => "direct"
      )

      replace_ref(project, ref, LocalRef) { |local_ref| local_ref.relative_path = relative_path }

      puts "Swapped '#{name}' to local checkout at #{relative_path} (kept resource id #{ref.uuid})"
    end

    def swap_local_to_remote(project, xcodeproj_path, ref, state)
      name = ref_name(ref)
      entry = state[name]
      unless entry && entry["repositoryURL"] && entry["requirement"]
        abort_with("no recorded remote reference for '#{name}' in #{@state_file}. " \
                    "Add \"repositoryURL\"/\"requirement\" for it manually, or restore project.pbxproj from git.")
      end

      # Backfill localPath in case this entry was created/edited by hand
      # without one, so the record stays complete going forward.
      entry["localPath"] ||= (xcodeproj_path.dirname + ref.relative_path).expand_path.to_s
      entry["type"] = "direct"

      replace_ref(project, ref, RemoteRef) do |remote_ref|
        remote_ref.repositoryURL = entry["repositoryURL"]
        remote_ref.requirement = entry["requirement"]
      end

      puts "Swapped '#{name}' back to remote reference #{entry["repositoryURL"]} (kept resource id #{ref.uuid})"
    end

    # Adds a brand-new, unlinked local reference for an indirect (transitive)
    # dependency. New UUID, since there's no existing ref to reuse one from.
    # Not wired into any target's product dependencies — its mere presence
    # in packageReferences is enough for SwiftPM to unify the identity with
    # the local checkout wherever else in the graph it's referenced
    # (verified: it overrides the transitive pin even when the package that
    # actually declares the dependency, e.g. my-shared-ios, stays remote).
    def add_indirect_local_ref(project, xcodeproj_path, candidate, state)
      name = candidate.name
      entry = state[name] || {}
      local_dir = resolve_local_dir(entry, name)
      relative_path = local_dir.relative_path_from(xcodeproj_path.dirname).to_s

      repository_url = entry["repositoryURL"] || candidate.resolved_entry["repositoryURL"]
      requirement = entry["requirement"] || candidate.resolved_entry["requirement"]

      new_ref = LocalRef.new(project, project.generate_uuid)
      new_ref.initialize_defaults
      new_ref.relative_path = relative_path
      project.root_object.package_references << new_ref

      state[name] = entry.merge(
        "repositoryURL" => repository_url,
        "requirement" => requirement,
        "localPath" => local_dir.to_s,
        "type" => "indirect"
      )

      puts "Added local override for '#{name}' (indirect dependency) at #{relative_path} (new resource id #{new_ref.uuid})"
    end

    def remove_indirect_ref(project, candidate)
      ref = candidate.ref
      product_dependencies_for(project, ref).each { |dep| dep.package = nil }
      project.root_object.package_references.delete(ref)

      puts "Removed local override for '#{candidate.name}' (indirect dependency)"
    end

    # Xcode holding the project open can silently overwrite project.pbxproj
    # out from under us (observed in practice: Xcode periodically re-saves
    # its in-memory state to disk). Ask before we touch the file.
    def check_xcode_running
      return unless xcode_running?

      puts "Xcode is currently running, which can overwrite project.pbxproj while it's being edited."
      puts "  1) I'll close it myself"
      puts "  2) Do nothing, proceed anyway"
      puts "  3) Close Xcode for me"
      print "> "
      choice = $stdin.gets&.strip

      case choice
      when "1"
        print "Close Xcode, then press Enter to continue... "
        $stdin.gets
        warn "warning: Xcode still appears to be running." if xcode_running?
      when "3"
        run_command("osascript", "-e", 'tell application "Xcode" to quit')
        wait_for_xcode_to_quit
      when "2"
        nil
      else
        abort_with("invalid selection")
      end
    end

    def xcode_running?
      run_command("pgrep", "-x", "Xcode", out: File::NULL, err: File::NULL)
    end

    # Thin wrapper around Kernel#system so every shell-out point in this
    # class can be stubbed from one place in tests, instead of each needing
    # its own indirection.
    def run_command(*args)
      system(*args)
    end

    # Overridable so tests can shrink these without a real 10-second wait.
    def xcode_quit_timeout
      10
    end

    def xcode_quit_poll_interval
      0.5
    end

    def wait_for_xcode_to_quit
      deadline = Time.now + xcode_quit_timeout
      sleep xcode_quit_poll_interval while xcode_running? && Time.now < deadline
      warn "warning: Xcode still appears to be running (it may be waiting on an unsaved-changes prompt)." if xcode_running?
    end

    def prompt_resolve?
      print "Resolve package dependencies now? [Y/n] "
      answer = $stdin.gets&.strip
      answer.nil? || answer.empty? || !answer.match?(/\An/i)
    end

    def prompt_open_in_xcode?
      print "Open in Xcode now? [Y/n] "
      answer = $stdin.gets&.strip
      answer.nil? || answer.empty? || !answer.match?(/\An/i)
    end

    def open_in_xcode(xcodeproj_path)
      target = find_workspace_path || xcodeproj_path
      warn "warning: could not open #{target} in Xcode." unless run_command("open", target.to_s)
    end

    # Prefers `-workspace <workspace> -scheme <scheme>` over `-project` when a
    # .xcworkspace exists, so resolution (and its Package.resolved output)
    # targets the same file discovery reads from — some repos keep a
    # separate top-level .xcworkspace whose Package.resolved is the one
    # actually tracked in git, distinct from the .xcodeproj's own implicit
    # workspace. Falls back to `-project` (no scheme needed) otherwise.
    def resolve_target_args(xcodeproj_path)
      workspace = find_workspace_path
      return ["-project", xcodeproj_path.to_s] unless workspace

      scheme = detect_scheme(xcodeproj_path, workspace)
      return ["-project", xcodeproj_path.to_s] unless scheme

      ["-workspace", workspace.to_s, "-scheme", scheme]
    end

    # Reads shared scheme files directly (no xcodebuild invocation, which
    # would otherwise trigger its own package resolution just to answer
    # "what schemes exist").
    def detect_scheme(xcodeproj_path, workspace)
      scheme_files = Dir.glob(xcodeproj_path + "xcshareddata/xcschemes/*.xcscheme").sort
      return nil if scheme_files.empty?

      preferred_name = workspace.basename(".xcworkspace").to_s
      preferred = scheme_files.find { |f| File.basename(f, ".xcscheme").casecmp(preferred_name).zero? }
      File.basename(preferred || scheme_files.first, ".xcscheme")
    end

    def resolve_package_dependencies(xcodeproj_path)
      puts "Resolving package dependencies (xcodebuild -resolvePackageDependencies)..."
      ok = run_command("xcodebuild", "-resolvePackageDependencies", *resolve_target_args(xcodeproj_path))
      return if ok

      warn "warning: automatic package resolution failed. Open the project in Xcode " \
           "(File > Packages > Resolve Package Versions) to finish updating Package.resolved."
    rescue Errno::ENOENT
      warn "warning: xcodebuild not found on PATH; skipped automatic package resolution. " \
           "Open the project in Xcode to resolve packages."
    end
  end
end
