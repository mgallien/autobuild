require 'autobuild/timestamps'
require 'autobuild/environment'
require 'autobuild/subcommand'

module Autobuild
    TARGETS = %w{import prepare build}
    
    # Basic block for the autobuilder
    #
    # The build is done in three phases:
    #   - import
    #   - prepare
    #   - build & install
    #
    # In the first stage checks the source out and/or updates it.
    #
    # In the second stage, packages create their dependency structure to handle
    # specific build systems. For instance, it is there that build systems like
    # CMake are handled so that reconfiguration happens if needed. In the same
    # way, it is there that code generation will happen as well.
    #
    # Finally, the build stage actually calls the package's build targets (of
    # the form "package_name-build", which will trigger the build if needed.
    #
    # <b>Autodetecting dependencies</b>
    # There are two sides in dependency autodetection. The first side is that
    # packages must declare what they provide. One example is the handling of
    # pkgconfig dependencies: packages must declare that they provide a
    # pkgconfig definition. This side of the autodetection must be done just
    # after the package's import, by overloading the #import method:
    #
    #   def import
    #     super
    #
    #     # Do autodetection and call Package#provides
    #   end
    #
    # Note that, in most cases, the overloaded import method *must* begin with
    # "super".
    #
    # The other side is the detection itself. That must be done by overloading
    # the #prepare method.
    class Package
	@@packages = {}
	@@provides = {}

	# the package name
	attr_reader     :name
	# set the source directory. If a relative path is given,
	# it is relative to Autobuild.srcdir. Defaults to #name
	attr_writer     :srcdir
        # set an insource sub directory that contains the real sources we want to
        # build. If an absolute path is given, we should fail with an error.
        # defaults to . the current directory
        attr_writer     :subsrcdir
	# set the installation directory. If a relative path is given,
	# it is relative to Autobuild.prefix. Defaults to ''
	attr_writer :prefix
        # Sets the log directory. If no value is set, the package will use
        # Autobuild.logdir
        attr_writer :logdir
	
	# Sets importer object for this package. Defined for backwards compatibility.
	# Use the #importer attribute instead
	def import=(value)
	    @importer = value
	end
	# Sets an importer object for this package
	attr_accessor :importer

	# The list of packages this one depends upon
	attr_reader :dependencies

	# Absolute path to the source directory. See #srcdir=
	def srcdir; File.expand_path(@srcdir || name, Autobuild.srcdir) end
        # Absolute path to the insource real directory. See #subsrcdir=
        def subsrcdir; File.expand_path(@subsrcdir || ".", srcdir) end
	# Absolute path to the installation directory. See #prefix=
	def prefix; File.expand_path(@prefix || '', Autobuild.prefix) end
        # Absolute path to the log directory for this package. See #logdir=
        def logdir; File.expand_path(@logdir || 'log', prefix) end

	# The file which marks when the last sucessful install
	# has finished. The path is absolute
	#
	# A package is sucessfully built when it is installed
	def installstamp
            File.join(logdir, "#{name}-#{STAMPFILE}")
        end

        attr_writer :updated

        # Returns true if this package has already been updated. It will not be
        # true if the importer has been called while Autobuild.do_update was
        # false.
        def updated?; !!@updated end

	def initialize(spec)
	    @dependencies   = Array.new
	    @provides       = Array.new
            @parallel_build_level = nil

	    if Hash === spec
		name, depends = spec.to_a.first
	    else
		name, depends = spec, nil
	    end

	    name = name.to_s
	    @name = name
	    raise ConfigException, "package #{name} is already defined" if Autobuild::Package[name]
	    @@packages[name] = self

	    # Call the config block (if any)
	    yield(self) if block_given?

            @doc_dir        ||= 'doc'
            @doc_target_dir ||= name

	    # Define the default tasks
	    task "#{name}-import" do import end
	    task :import => "#{name}-import"

	    # Define the prepare task
	    task "#{name}-prepare" => "#{name}-import" do prepare end
	    task :prepare => "#{name}-prepare"

	    task "#{name}-build" => "#{name}-prepare"
	    task :build => "#{name}-build"

	    task(name) do
		Rake::Task["#{name}-import"].invoke
		Rake::Task["#{name}-prepare"].invoke
		Rake::Task["#{name}-build"].invoke
                if has_doc? && Autobuild.do_doc
                    Rake::Task["#{name}-doc"].invoke
                end
	    end
	    task :default => name
	    
            # The dependencies will be declared in the import phase,  so save
            # them there for now
            @spec_dependencies = depends
	end

        # Called before a forced build. It should remove all the timestamp and
        # target files so that all the build phases of this package gets
        # retriggered. However, it should not clean the build products.
        def prepare_for_forced_build
            if File.exists?(installstamp)
                FileUtils.rm_f installstamp
            end
        end

        # Called when the user asked for a full rebuild. It should delete the
        # build products so that a full build is retriggered.
        def prepare_for_rebuild
            if File.exists?(installstamp)
                FileUtils.rm_f installstamp
            end
        end

        # Call the importer if there is one. Autodetection of "provides" should
        # be done there as well. See the documentation of Autobuild::Package for
        # more information.
	def import
            @importer.import(self) if @importer

	    # Add the dependencies declared in spec
	    depends_on *@spec_dependencies if @spec_dependencies

            if File.directory?(prefix)
                Autobuild.update_environment prefix
            end
        end

        # Create all the dependencies required to reconfigure and/or rebuild the
        # package when required. The package's build target is called
        # "package_name-build".
	def prepare
            super if defined? super

            stamps = dependencies.map { |p| Package[p].installstamp }

	    file installstamp => stamps do
                install
	    end
            task "#{name}-build" => installstamp
        end

        # Display a progress message. %s in the string is replaced by the
        # package name
        def progress(msg)
            Autobuild.progress(msg % [name])
        end

        # Display a progress message, and later on update it with a progress
        # value. %s in the string is replaced by the package name
        def progress_with_value(msg)
            Autobuild.progress_with_value(msg % [name])
        end

        def progress_value(value)
            Autobuild.progress_value(value)
        end

        # Install the result in prefix
        def install
            Dir.chdir(subsrcdir) do
                Autobuild.apply_post_install(name, @post_install)
            end
            Autobuild.touch_stamp(installstamp)
            Autobuild.update_environment prefix
        end

        def run(*args, &block)
            Autobuild::Subprocess.run(self, *args, &block)
        end

        # Directory in which the documentation target will have generated the
        # documentation (if any). The interpretation of relative directories
        # is package-specific. The default implementation interpret them
        # as relative to the source directory, but packages like CMake will
        # interpret them as relative to their build directories.
        attr_writer :doc_dir

        # Absolute path to where documentation is generated. Returns nil if the
        # doc_dir attribute is not set.
        def doc_dir
            if @doc_dir
                File.expand_path(@doc_dir, subsrcdir)
            end
        end

        # Directory in which the documentation target should install the
        # documentation. If it is relative, it is interpreted as relative to
        # the documentation prefix directory (Autobuild.doc_prefix)
        attr_writer :doc_target_dir

        # Absolute path to where documentation has to be installed. Returns nil
        # if the doc_target_dir attribute is not set.
        def doc_target_dir
            if @doc_target_dir
                File.expand_path(@doc_target_dir, File.expand_path(Autobuild.doc_prefix || '.',  prefix))
            end
        end

        # Defines a documentation generation task. The documentation is first
        # generated by the given block, and then installed. The local attribute
        # #doc_dir defines where the documentation is generated by the
        # package's build system, and the #doc_target_dir and
        # Autobuild.doc_prefix attributes define where it should be installed.
        #
        # The block is invoked in the package's source directory
        #
        # In general, specific package types define a meaningful #with_doc
        # method which calls this method internally.
        def doc_task
            task "#{name}-doc" => "#{name}-build" do
                @installed_doc = false
                catch(:doc_disabled) do
                    begin
                        Dir.chdir(subsrcdir) do
                            yield if block_given?
                        end

                        unless @installed_doc
                            install_doc
                        end

                    rescue Exception => e
                        if Autobuild.doc_errors
                            raise
                        else
                            STDERR.puts "W: failed to generate documentation for #{name}"
                            if e.kind_of?(SubcommandFailed)
                                STDERR.puts "W: see #{e.logfile} for more details"
                            end
                        end
                    end
                end
            end

            task :doc => "#{name}-doc"
        end

        def install_doc
            doc_target_dir  = self.doc_target_dir
            doc_dir         = self.doc_dir
            FileUtils.rm_rf   doc_target_dir
            FileUtils.mkdir_p File.dirname(doc_target_dir)
            FileUtils.cp_r    doc_dir, doc_target_dir

            @installed_doc = true
        end

        # Can be called in the doc_task implementation to announce that the
        # documentation is to be disabled for that package. This is mainly used
        # when a runtime check is necessary to know if a package has
        # documentation or not.
        def doc_disabled
            throw :doc_disabled
        end

        # True if a documentation task is defined for this package
        def has_doc?
            !!Rake.application.lookup("#{name}-doc")
        end

	def post_install(*args, &block)
	    if args.empty?
		@post_install = block
	    elsif !block
		@post_install = args
	    else
		raise ArgumentError, "cannot set both arguments and block"
	    end
	end

        # Returns true if this package depends on +package_name+ and false
        # otherwise.
        def depends_on?(package_name)
            @dependencies.include?(package_name)
        end

	# This package depends on +packages+. It means that its build will
        # always be triggered after the packages listed in +packages+ are built
        # and installed.
	def depends_on(*packages)
	    packages.each do |p|
                raise ConfigException, "#{p.inspect} should be a string" if !p.respond_to? :to_str
		p = p.to_str
		next if p == name
		unless pkg = Package[p]
		    raise ConfigException.new(name), "package #{p} not defined"
		end

                next if @dependencies.include?(pkg.name)

                if Autobuild.verbose
                    STDERR.puts "  #{name} depends on #{pkg.name}"
                end

		task "#{name}-import"  => "#{pkg.name}-import"
		task "#{name}-prepare" => "#{pkg.name}-prepare"
		task "#{name}-build"   => "#{pkg.name}-build"
		@dependencies << pkg.name
	    end
	end

	# Declare that this package provides +packages+. In effect, the names
        # listed in +packages+ are aliases for this package.
	def provides(*packages)
	    packages.each do |p|
                raise ConfigException, "#{p.inspect} should be a string" if !p.respond_to? :to_str
		p = p.to_str
		next if p == name
                next if @provides.include?(name)

		@@provides[p] = self 

                if Autobuild.verbose
                    STDERR.puts "  #{name} provides #{p}"
                end

		task p => name
		task "#{p}-import" => "#{name}-import"
		task "#{p}-prepare" => "#{name}-prepare"
		task "#{p}-build" => "#{name}-build"
		@provides << p
	    end
	end

	# Iterates on all available packages
	# if with_provides is true, includes the list
	# of package aliases
	def self.each(with_provides = false, &p)
            if !p
                return enum_for(:each, with_provides)
            end

	    @@packages.each(&p) 
	    @@provides.each(&p) if with_provides
	end

	# Gets a package from its name
	def self.[](name)
	    @@packages[name.to_s] || @@provides[name.to_s]
	end

        # Sets the level of parallelism authorized while building this package
        #
        # See #parallel_build_level and Autobuild.parallel_build_level for more
        # information.
        #
        # Note that not all package types use this value
        def parallel_build_level=(value)
            @parallel_build_level = Integer(value)
        end

        # Returns the level of parallelism authorized during the build for this
        # particular package. If not set, defaults to the system-wide option 
        # (Autobuild.parallel_build_level and Autobuild.parallel_build_level=).
        #
        # The default value is the number of CPUs on this system.
        def parallel_build_level
            if @parallel_build_level.nil?
                Autobuild.parallel_build_level
            elsif !@parallel_build_level || @parallel_build_level <= 0
                1
            else
                @parallel_build_level
            end
        end
    end

    def self.package_set(spec)
	spec.each do |name, packages|
	    Autobuild::TARGETS.each do |target|
		task "#{name}-#{target}" => packages.map { |dep| "#{dep}-#{target}" }
	    end
	end
    end
end

