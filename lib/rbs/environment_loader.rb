# frozen_string_literal: true

module RBS
  class EnvironmentLoader
    class UnknownLibraryError < StandardError
      attr_reader :library

      def initialize(lib:)
        @library = lib

        super("Cannot find type definitions for library: #{lib.name} (#{lib.version || "[nil]"})")
      end
    end

    Library = _ = Struct.new(:name, :version, keyword_init: true)

    attr_reader :core_root
    attr_reader :repository

    attr_reader :libs
    attr_reader :dirs

    DEFAULT_CORE_ROOT = Pathname(_ = __dir__) + "../../core"

    def self.gem_sig_path(name, version)
      requirements = []
      requirements << version if version
      spec = Gem::Specification.find_by_name(name, *requirements)
      path = Pathname(spec.gem_dir) + "sig"
      if path.directory?
        [spec, path]
      end
    rescue Gem::MissingSpecError
      nil
    end

    def initialize(core_root: DEFAULT_CORE_ROOT, repository: Repository.new)
      @core_root = core_root
      @repository = repository

      @libs = Set.new
      @dirs = []
    end

    def add(path: nil, library: nil, version: nil, resolve_dependencies: true)
      case
      when path
        dirs << path
      when library
        if library == 'rubygems'
          RBS.logger.warn '`rubygems` has been moved to core library, so it is always loaded. Remove explicit loading `rubygems`'
          return
        end

        if libs.add?(Library.new(name: library, version: version)) && resolve_dependencies
          resolve_dependencies(library: library, version: version)
        end
      end
    end

    def resolve_dependencies(library:, version:)
      [Collection::Sources::Rubygems.instance, Collection::Sources::Stdlib.instance].each do |source|
        next unless source.has?(library, version)

        unless version
          version = source.versions(library).last or raise
        end

        source.dependencies_of(library, version)&.each do |dep|
          add(library: dep['name'], version: nil)
        end
        return
      end
    end

    def add_collection(lockfile)
      lockfile.check_rbs_availability!

      repository.add(lockfile.fullpath)

      lockfile.gems.each_value do |gem|
        add(library: gem[:name], version: gem[:version], resolve_dependencies: false)
      end
    end

    def has_library?(library:, version:)
      if self.class.gem_sig_path(library, version) || repository.lookup(library, version)
        true
      else
        false
      end
    end

    def load(env:)
      # @type var loaded: Array[[AST::Declarations::t, Pathname, source]]
      loaded = []

      each_decl do |decl, buf, source, path|
        env << decl
        loaded << [decl, path, source]
      end

      loaded
    end

    def each_dir
      if root = core_root
        yield :core, root
      end

      libs.each do |lib|
        unless has_library?(version: lib.version, library: lib.name)
          raise UnknownLibraryError.new(lib: lib)
        end

        case
        when from_gem = self.class.gem_sig_path(lib.name, lib.version)
          yield lib, from_gem[1]
        when from_repo = repository.lookup(lib.name, lib.version)
          yield lib, from_repo
        end
      end

      dirs.each do |dir|
        yield dir, dir
      end
    end

    def each_file(path, immediate:, skip_hidden:, &block)
      case
      when path.file?
        if path.extname == ".rbs" || immediate
          yield path
        end

      when path.directory?
        if path.basename.to_s.start_with?("_")
          if skip_hidden
            unless immediate
              return
            end
          end
        end

        path.children.sort.each do |child|
          each_file(child, immediate: false, skip_hidden: skip_hidden, &block)
        end
      end
    end

    def each_decl
      files = Set[]

      each_dir do |source, dir|
        skip_hidden = !source.is_a?(Pathname)

        each_file(dir, skip_hidden: skip_hidden, immediate: true) do |path|
          next if files.include?(path)

          files << path
          buffer = Buffer.new(name: path.to_s, content: path.read(encoding: "UTF-8"))

          _, _dirs, decls = Parser.parse_signature(buffer)

          decls.each do |decl|
            yield decl, buffer, source, path
          end
        end
      end
    end
  end
end
