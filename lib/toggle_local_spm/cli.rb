# frozen_string_literal: true

require "xcodeproj"
require "json"
require "pathname"

module ToggleLocalSpm
  # Toggles one or more Swift Package Manager dependencies in the .xcodeproj
  # found in the current directory between their remote (git) reference and a
  # local checkout. Run again on the same package to swap back to the
  # original remote reference. Afterwards, optionally runs
  # `xcodebuild -resolvePackageDependencies` so Package.resolved is updated
  # to match (requires network access and, for private repos, a working SSH
  # key).
  #
  # Run from the root of the Xcode project's repo (the directory containing
  # the .xcodeproj). A `spm-local-overrides.json` file is kept at the repo
  # root as a permanent record of each package's remote reference and local
  # checkout path (see README) — which reference type (remote vs. local) is
  # currently wired up in the pbxproj is always the source of truth for
  # whether a package is "on" (local) or "off" (remote), not this file.
  class CLI
    RemoteRef = Xcodeproj::Project::Object::XCRemoteSwiftPackageReference
    LocalRef = Xcodeproj::Project::Object::XCLocalSwiftPackageReference
    ProductDependency = Xcodeproj::Project::Object::XCSwiftPackageProductDependency

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
      package_refs = project.root_object.package_references.select { |r| r.is_a?(RemoteRef) || r.is_a?(LocalRef) }
      abort_with("no Swift package dependencies found in the project") if package_refs.empty?

      state = load_state
      selected_refs = select_packages(package_refs)

      selected_refs.each do |ref|
        if ref.is_a?(RemoteRef)
          swap_remote_to_local(project, xcodeproj_path, ref, state)
        else
          swap_local_to_remote(project, xcodeproj_path, ref, state)
        end
      end

      save_state(state)
      project.save

      resolve_package_dependencies(xcodeproj_path) if prompt_resolve?

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

    def load_state
      return {} unless @state_file.exist?

      JSON.parse(@state_file.read)
    rescue JSON::ParserError => e
      abort_with("could not parse #{@state_file}: #{e.message}")
    end

    # The state file is a permanent record: it is created on first use and
    # never deleted, and entries are only ever added to or updated, never
    # removed — even after a package is swapped back to remote. This lets a
    # developer hand-edit a package's "localPath" (e.g. to point at a
    # differently-located or differently-named checkout) without losing the
    # recorded repositoryURL/requirement needed to swap back to remote.
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

    def find_package(package_refs, wanted)
      match = package_refs.find { |ref| ref_name(ref).casecmp(wanted).zero? }
      return match if match

      names = package_refs.map { |ref| ref_name(ref) }.sort
      abort_with("no package dependency named '#{wanted}'. Available: #{names.join(", ")}")
    end

    def select_packages(package_refs)
      return @package_names.map { |wanted| find_package(package_refs, wanted) }.uniq if @package_names.any?

      select_packages_interactively(package_refs)
    end

    def select_packages_interactively(package_refs)
      puts "Select package dependencies to toggle (e.g. 1, or 1 3):"
      package_refs.each_with_index do |ref, i|
        kind = ref.is_a?(RemoteRef) ? "remote" : "local"
        puts "  #{i + 1}) #{ref_name(ref)} [#{kind}]"
      end
      print "> "
      choice = $stdin.gets&.strip
      abort_with("invalid selection") if choice.nil? || choice.empty?

      tokens = choice.split(/[\s,]+/)
      abort_with("invalid selection '#{choice}'") unless tokens.all? { |t| t.match?(/\A\d+\z/) }

      tokens.map(&:to_i).map do |n|
        index = n - 1
        abort_with("invalid selection '#{n}'") unless index.between?(0, package_refs.size - 1)
        package_refs[index]
      end.uniq
    end

    def swap_remote_to_local(project, xcodeproj_path, ref, state)
      name = ref_name(ref)
      entry = state[name] || {}

      local_dir = entry["localPath"] ? Pathname.new(entry["localPath"]).expand_path(@root) : (@root.parent + name)
      unless local_dir.directory? && (local_dir + "Package.swift").file?
        abort_with("expected a local checkout with a Package.swift at #{local_dir} " \
                   "(set or fix \"localPath\" for '#{name}' in #{@state_file} if it lives elsewhere)")
      end

      relative_path = local_dir.relative_path_from(xcodeproj_path.dirname).to_s

      state[name] = entry.merge(
        "repositoryURL" => ref.repositoryURL,
        "requirement" => ref.requirement,
        "localPath" => local_dir.to_s
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

      replace_ref(project, ref, RemoteRef) do |remote_ref|
        remote_ref.repositoryURL = entry["repositoryURL"]
        remote_ref.requirement = entry["requirement"]
      end

      puts "Swapped '#{name}' back to remote reference #{entry["repositoryURL"]} (kept resource id #{ref.uuid})"
    end

    def prompt_resolve?
      print "Resolve package dependencies now? [Y/n] "
      answer = $stdin.gets&.strip
      answer.nil? || answer.empty? || !answer.match?(/\An/i)
    end

    def resolve_package_dependencies(xcodeproj_path)
      puts "Resolving package dependencies (xcodebuild -resolvePackageDependencies)..."
      ok = system("xcodebuild", "-resolvePackageDependencies", "-project", xcodeproj_path.to_s)
      return if ok

      warn "warning: automatic package resolution failed. Open the project in Xcode " \
           "(File > Packages > Resolve Package Versions) to finish updating Package.resolved."
    rescue Errno::ENOENT
      warn "warning: xcodebuild not found on PATH; skipped automatic package resolution. " \
           "Open the project in Xcode to resolve packages."
    end
  end
end
