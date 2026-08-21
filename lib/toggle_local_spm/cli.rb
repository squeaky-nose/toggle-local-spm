# frozen_string_literal: true

require "xcodeproj"
require "json"
require "pathname"

module ToggleLocalSpm
  # Toggles a Swift Package Manager dependency in the .xcodeproj found in the
  # current directory between its remote (git) reference and a local checkout
  # in an adjacent sibling folder (e.g. ../<package-name>). Run again on the
  # same package to swap back to the original remote reference. Afterwards
  # runs `xcodebuild -resolvePackageDependencies` so Package.resolved is
  # updated to match (requires network access and, for private repos, a
  # working SSH key).
  #
  # Run from the root of the Xcode project's repo (the directory containing
  # the .xcodeproj), with the local checkout of the dependency expected to be
  # an adjacent sibling directory.
  class CLI
    RemoteRef = Xcodeproj::Project::Object::XCRemoteSwiftPackageReference
    LocalRef = Xcodeproj::Project::Object::XCLocalSwiftPackageReference
    ProductDependency = Xcodeproj::Project::Object::XCSwiftPackageProductDependency

    def self.run(argv)
      new(argv).run
    end

    def initialize(argv, root: Dir.pwd)
      @package_name = argv[0]
      @root = Pathname.new(root).expand_path
      @state_file = @root + ".spm-local-overrides.json"
    end

    def run
      xcodeproj_path = find_xcodeproj_path
      project = Xcodeproj::Project.open(xcodeproj_path)
      package_refs = project.root_object.package_references.select { |r| r.is_a?(RemoteRef) || r.is_a?(LocalRef) }
      abort_with("no Swift package dependencies found in the project") if package_refs.empty?

      state = load_state
      selected = select_package(package_refs)

      if selected.is_a?(RemoteRef)
        swap_remote_to_local(project, xcodeproj_path, selected, state)
      else
        swap_local_to_remote(project, selected, state)
      end

      save_state(state)
      project.save

      resolve_package_dependencies(xcodeproj_path)

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

    def save_state(state)
      if state.empty?
        @state_file.delete if @state_file.exist?
      else
        @state_file.write(JSON.pretty_generate(state) + "\n")
      end
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

    def select_package(package_refs)
      if @package_name
        match = package_refs.find { |ref| ref_name(ref).casecmp(@package_name).zero? }
        unless match
          names = package_refs.map { |ref| ref_name(ref) }.sort
          abort_with("no package dependency named '#{@package_name}'. Available: #{names.join(", ")}")
        end
        return match
      end

      puts "Select a package dependency to toggle:"
      package_refs.each_with_index do |ref, i|
        kind = ref.is_a?(RemoteRef) ? "remote" : "local"
        puts "  #{i + 1}) #{ref_name(ref)} [#{kind}]"
      end
      print "> "
      choice = $stdin.gets&.strip
      index = choice.to_i - 1
      abort_with("invalid selection") unless choice&.match?(/\A\d+\z/) && index.between?(0, package_refs.size - 1)
      package_refs[index]
    end

    def swap_remote_to_local(project, xcodeproj_path, ref, state)
      name = ref_name(ref)
      sibling_dir = @root.parent + name
      unless sibling_dir.directory? && (sibling_dir + "Package.swift").file?
        abort_with("expected a local checkout with a Package.swift at #{sibling_dir}")
      end

      relative_path = sibling_dir.relative_path_from(xcodeproj_path.dirname).to_s

      state[name] = {
        "repositoryURL" => ref.repositoryURL,
        "requirement" => ref.requirement
      }

      replace_ref(project, ref, LocalRef) { |local_ref| local_ref.relative_path = relative_path }

      puts "Swapped '#{name}' to local checkout at #{relative_path} (kept resource id #{ref.uuid})"
    end

    def swap_local_to_remote(project, ref, state)
      name = ref_name(ref)
      saved = state[name]
      unless saved
        abort_with("no saved remote reference for '#{name}' (it wasn't swapped to local by this tool). " \
                    "Remove it manually in Xcode or restore project.pbxproj from git.")
      end

      replace_ref(project, ref, RemoteRef) do |remote_ref|
        remote_ref.repositoryURL = saved["repositoryURL"]
        remote_ref.requirement = saved["requirement"]
      end
      state.delete(name)

      puts "Swapped '#{name}' back to remote reference #{saved["repositoryURL"]} (kept resource id #{ref.uuid})"
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
