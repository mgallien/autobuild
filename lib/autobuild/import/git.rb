require 'fileutils'
require 'autobuild/subcommand'
require 'autobuild/importer'
require 'utilrb/kernel/options'

module Autobuild
    class Git < Importer
        # Creates an importer which tracks the given repository
        # and branch. +source+ is [repository, branch]
        #
        # This importer uses the 'git' tool to perform the
        # import. It defaults to 'svn' and can be configured by
        # doing 
	#   Autobuild.programs['git'] = 'my_git_tool'
        def initialize(repository, branch = nil, options = {})
            @repository = repository.to_str

            if branch.respond_to?(:to_hash)
                options = branch.to_hash
                branch = nil
            end

            if branch
                STDERR.puts "WARN: the git importer now expects you to provide the branch as a named option"
                STDERR.puts "WARN: this form is deprecated:"
                STDERR.puts "WARN:    Autobuild.git 'git://github.com/doudou/autobuild.git', 'master'"
                STDERR.puts "WARN: and should be replaced by"
                STDERR.puts "WARN:    Autobuild.git 'git://github.com/doudou/autobuild.git', :branch => 'master'"
            end

            gitopts, common = Kernel.filter_options options, :branch => nil, :tag => nil, :commit => nil
            if gitopts[:branch] && branch
                raise ConfigException, "git branch specified with both the option hash and the explicit parameter"
            end
            branch = gitopts[:branch] || branch
            tag    = gitopts[:tag]
            commit = gitopts[:commit]

            if (branch && commit) || (branch && tag) || (tag && commit)
                raise ConfigException, "you can specify only a branch, tag or commit but not two or three at the same time"
            end
            @branch = branch || 'master'
            @tag    = tag
            @commit = commit
            super(common)
        end

        attr_accessor :repository

        # The branch this importer is tracking
        #
        # If set, both commit and tag have to be nil.
        attr_accessor :branch

        # The tag we are pointing to. It is a tag name.
        #
        # If set, both branch and commit have to be nil.
        attr_reader :tag

        # The commit we are pointing to. It is a commit ID.
        #
        # If set, both branch and tag have to be nil.
        attr_reader :commit

        # True if it is allowed to merge remote updates automatically. If false
        # (the default), the import will fail if the updates do not resolve as
        # a fast-forward
        def merge?; !!@merge end

        # Set the merge flag. See #merge?
        def merge=(flag); @merge = flag end

        # Raises ConfigException if the current directory is not a git
        # repository
        def validate_srcdir(package)
            if !File.directory?(File.join(package.srcdir, '.git'))
                raise ConfigException, "while importing #{package.name}, #{package.srcdir} is not a git repository"
            end
        end

        # Fetches updates from the remote repository. Returns the remote commit
        # ID on success, nil on failure. Expects the current directory to be the
        # package's source directory.
        def fetch_remote(package)
            validate_srcdir(package)
            Dir.chdir(package.srcdir) do
                # Update the remote definition
                Subprocess.run(package, :import, Autobuild.tool('git'), 'config',
                               "--replace-all", "remote.autobuild.url", repository)
                Subprocess.run(package, :import, Autobuild.tool('git'), 'config',
                               "--replace-all", "remote.autobuild.fetch",  "+refs/heads/*:refs/remotes/autobuild/*")

                # We are checking out a specific commit. We just call git fetch
                if commit
                    Subprocess.run(package, :import, Autobuild.tool('git'), 'fetch', 'autobuild')
                elsif tag
                    Subprocess.run(package, :import, Autobuild.tool('git'), 'fetch', repository, "tags/#{tag}")
                else
                    Subprocess.run(package, :import, Autobuild.tool('git'), 'fetch', repository, branch)
                end

                # Now get the actual commit ID from the FETCH_HEAD file, and
                # return it
                commit_id = if File.readable?( File.join('.git', 'FETCH_HEAD') )
                    fetch_commit = File.readlines( File.join('.git', 'FETCH_HEAD') ).
                        delete_if { |l| l =~ /not-for-merge/ }
                    if !fetch_commit.empty?
                        fetch_commit.first.split(/\s+/).first
                    end
                end

                # Update the remote tag if needs be
                if branch && commit_id
                    Subprocess.run(package, :import, Autobuild.tool('git'), 'update-ref',
                                   "-m", "updated by autobuild", "refs/remotes/autobuild/#{branch}", commit_id)
                end

                commit_id
            end
        end

        # Returns a Importer::Status object that represents the status of this
        # package w.r.t. the root repository
        def status(package)
            validate_srcdir(package)
            Dir.chdir(package.srcdir) do
                remote_commit = fetch_remote(package)
                if !remote_commit
                    return
                end

                status = merge_status(remote_commit)
                `git diff --quiet`
                if $?.exitstatus != 0
                    status.uncommitted_code = true
                end
                status
            end
        end

        # Checks if the current branch is the target branch. Expects that the
        # current directory is the package's directory
        def on_target_branch?
            current_branch = `git symbolic-ref HEAD`.chomp
            current_branch == "refs/heads/#{branch}"
        end

        class Status < Importer::Status
            attr_reader :fetch_commit
            attr_reader :head_commit
            attr_reader :common_commit

            def initialize(status, remote_commit, local_commit, common_commit)
                super()
                @status        = status
                @fetch_commit  = fetch_commit
                @head_commit   = head_commit
                @common_commit = common_commit

                if remote_commit != common_commit
                    @remote_commits = log(common_commit, remote_commit)
                end
                if local_commit != common_commit
                    @local_commits = log(common_commit, local_commit)
                end
            end

            def needs_update?
                status == Status::NEEDS_MERGE || status == Status::SIMPLE_UPDATE
            end

            def log(from, to)
                log = `git log --pretty=format:"%h %cr %cn %s" #{from}..#{to}`
                if log.respond_to?(:force_encoding)
                    log.force_encoding('UTF-8')
                end
                log.chomp.split("\n")
            end
        end

        def merge_status(fetch_commit)
            common_commit = `git merge-base HEAD #{fetch_commit}`.chomp
            head_commit   = `git rev-parse #{branch}`.chomp

            status = if common_commit != fetch_commit
                         if common_commit == head_commit
                             Status::SIMPLE_UPDATE
                         else
                             Status::NEEDS_MERGE
                         end
                     else
                         if common_commit == head_commit
                             Status::UP_TO_DATE
                         else
                             Status::ADVANCED
                         end
                     end

            Status.new(status, fetch_commit, head_commit, common_commit)
        end

        def update(package)
            validate_srcdir(package)
            Dir.chdir(package.srcdir) do
                fetch_commit = fetch_remote(package)
                if !fetch_commit
                    return
                end

                # If we are tracking a commit/tag, just check it out and return
                if commit || tag
                    Subprocess.run(package, :import, Autobuild.tool('git'), 'checkout', commit || tag)
                    return
                end

                if !on_target_branch?
                    # Check if the target branch already exists. If it is the
                    # case, check it out. Otherwise, create it.
                    if File.file?(File.join(".git", "refs", "heads", branch))
                        Subprocess.run(package, :import, Autobuild.tool('git'), 'checkout', branch)
                    else
                        Subprocess.run(package, :import, Autobuild.tool('git'), 'checkout', '-b', branch, "FETCH_HEAD")
                    end
                end

                status = merge_status(fetch_commit)
                if status.needs_update?
                    if !merge? && status.status == Status::NEEDS_MERGE
                        raise PackageException, "importing the current version of #{package.name} would require a merge"
                    end
                    Subprocess.run(package, :import, Autobuild.tool('git'), 'merge', fetch_commit)
                end
            end
        end

        def checkout(package)
            base_dir = File.expand_path('..', package.srcdir)
            if !File.directory?(base_dir)
                FileUtils.mkdir_p base_dir
            end

            Subprocess.run(package, :import,
                Autobuild.tool('git'), 'clone', '-o', 'autobuild',
                repository, package.srcdir)

            Dir.chdir(package.srcdir) do
                # If we are tracking a commit/tag, just check it out
                if commit || tag
                    Subprocess.run(package, :import, Autobuild.tool('git'),
                        'checkout', commit || tag)
                    return
                end

                current_branch = `git symbolic-ref HEAD`.chomp
                if current_branch == "refs/heads/#{branch}"
                    Subprocess.run(package, :import, Autobuild.tool('git'),
                    'reset', '--hard', "autobuild/#{branch}")
                else
                    Subprocess.run(package, :import, Autobuild.tool('git'),
                    'checkout', '-b', branch, "autobuild/#{branch}")
                end
            end
        end
    end

    # Creates a git importer which gets the source for the given repository and branch
    # URL +source+. The allowed values in +options+ are described in SVN.new.
    def self.git(repository, branch = nil, options = {})
        Git.new(repository, branch, options)
    end
end

