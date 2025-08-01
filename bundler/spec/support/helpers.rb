# frozen_string_literal: true

require_relative "the_bundle"
require_relative "path"
require_relative "options"
require_relative "subprocess"

module Spec
  module Helpers
    include Spec::Path
    include Spec::Options
    include Spec::Subprocess

    def self.extended(mod)
      mod.extend Spec::Path
      mod.extend Spec::Options
      mod.extend Spec::Subprocess
    end

    def reset!
      Dir.glob("#{tmp}/{gems/*,*}", File::FNM_DOTMATCH).each do |dir|
        next if %w[base base_system remote1 rubocop standard gems rubygems . ..].include?(File.basename(dir))
        FileUtils.rm_r(dir)
      end
      FileUtils.mkdir_p(home)
      FileUtils.mkdir_p(tmpdir)
      Bundler.reset!
      Gem.clear_paths
    end

    def the_bundle(*args)
      TheBundle.new(*args)
    end

    MAJOR_DEPRECATION = /^\[DEPRECATED\]\s*/

    def err_without_deprecations
      err.gsub(/#{MAJOR_DEPRECATION}.+[\n]?/, "")
    end

    def deprecations
      err.split("\n").select {|l| l =~ MAJOR_DEPRECATION }.join("\n").split(MAJOR_DEPRECATION)
    end

    def run(cmd, *args)
      opts = args.last.is_a?(Hash) ? args.pop : {}
      groups = args.map(&:inspect).join(", ")
      setup = "require 'bundler' ; Bundler.ui.silence { Bundler.setup(#{groups}) }"
      ruby([setup, cmd].join(" ; "), opts)
    end

    def load_error_run(ruby, name, *args)
      cmd = <<-RUBY
        begin
          #{ruby}
        rescue LoadError => e
          warn "ZOMG LOAD ERROR" if e.message.include?("-- #{name}")
        end
      RUBY
      opts = args.last.is_a?(Hash) ? args.pop : {}
      args += [opts]
      run(cmd, *args)
    end

    def in_bundled_app(cmd, options = {})
      sys_exec(cmd, dir: bundled_app, raise_on_error: options[:raise_on_error])
    end

    def bundle(cmd, options = {}, &block)
      bundle_bin = options.delete(:bundle_bin)
      bundle_bin ||= installed_bindir.join("bundle")

      env = options.delete(:env) || {}

      requires = options.delete(:requires) || []

      dir = options.delete(:dir) || bundled_app
      custom_load_path = options.delete(:load_path)

      load_path = []
      load_path << custom_load_path if custom_load_path

      build_env_options = { load_path: load_path, requires: requires, env: env }
      build_env_options.merge!(artifice: options.delete(:artifice)) if options.key?(:artifice) || cmd.start_with?("exec")

      match_source(cmd)

      env = build_env(build_env_options)

      raise_on_error = options.delete(:raise_on_error)

      args = options.map do |k, v|
        case v
        when true
          " --#{k}"
        when false
          " --no-#{k}"
        else
          " --#{k} #{v}"
        end
      end.join

      cmd = "#{Gem.ruby} #{bundle_bin} #{cmd}#{args}"
      sys_exec(cmd, { env: env, dir: dir, raise_on_error: raise_on_error }, &block)
    end

    def main_source(dir)
      gemfile = File.expand_path("Gemfile", dir)
      return unless File.exist?(gemfile)

      match = File.readlines(gemfile).first.match(/source ["'](?<source>[^"']+)["']/)
      return unless match

      match[:source]
    end

    def bundler(cmd, options = {})
      options[:bundle_bin] = system_gem_path("bin/bundler")
      bundle(cmd, options)
    end

    def ruby(ruby, options = {})
      env = build_env({ artifice: nil }.merge(options))
      escaped_ruby = ruby.shellescape
      options[:env] = env if env
      options[:dir] ||= bundled_app
      sys_exec(%(#{Gem.ruby} -w -e #{escaped_ruby}), options)
    end

    def load_error_ruby(ruby, name, opts = {})
      ruby(<<-R)
        begin
          #{ruby}
        rescue LoadError => e
          warn "ZOMG LOAD ERROR" if e.message.include?("-- #{name}")
        end
      R
    end

    def build_env(options = {})
      env = options.delete(:env) || {}
      libs = options.delete(:load_path) || []
      env["RUBYOPT"] = opt_add("-I#{libs.join(File::PATH_SEPARATOR)}", env["RUBYOPT"]) if libs.any?

      current_example = RSpec.current_example

      main_source = @gemfile_source if defined?(@gemfile_source)
      compact_index_main_source = main_source&.start_with?("https://gem.repo", "https://gems.security")

      requires = options.delete(:requires) || []
      requires << hax

      artifice = options.delete(:artifice) do
        if current_example && current_example.metadata[:realworld]
          "vcr"
        elsif compact_index_main_source
          env["BUNDLER_SPEC_GEM_REPO"] ||=
            case main_source
            when "https://gem.repo1" then gem_repo1.to_s
            when "https://gem.repo2" then gem_repo2.to_s
            when "https://gem.repo3" then gem_repo3.to_s
            when "https://gem.repo4" then gem_repo4.to_s
            when "https://gems.security" then security_repo.to_s
            end

          "compact_index"
        else
          "fail"
        end
      end
      if artifice
        requires << "#{Path.spec_dir}/support/artifice/#{artifice}.rb"
      end

      requires.each {|r| env["RUBYOPT"] = opt_add("-r#{r}", env["RUBYOPT"]) }

      env
    end

    def gembin(cmd, options = {})
      cmd = bundled_app("bin/#{cmd}") unless cmd.to_s.include?("/")
      sys_exec(cmd.to_s, options)
    end

    def gem_command(command, options = {})
      env = options[:env] || {}
      env["RUBYOPT"] = opt_add(opt_add("-r#{hax}", env["RUBYOPT"]), ENV["RUBYOPT"])
      options[:env] = env

      # Sometimes `gem install` commands hang at dns resolution, which has a
      # default timeout of 60 seconds. When that happens, the timeout for a
      # command is expired too. So give `gem install` commands a bit more time.
      options[:timeout] = 120

      allowed_warning = options.delete(:allowed_warning)

      output = sys_exec("#{Path.gem_bin} #{command}", options)
      stderr = last_command.stderr

      raise stderr if stderr.include?("WARNING") && !allowed_rubygems_warning?(stderr, allowed_warning)
      output
    end

    def sys_exec(cmd, options = {}, &block)
      env = options[:env] || {}
      env["RUBYOPT"] = opt_add(opt_add("-r#{spec_dir}/support/switch_rubygems.rb", env["RUBYOPT"]), ENV["RUBYOPT"])
      options[:env] = env

      sh(cmd, options, &block)
    end

    def config(config = nil, path = bundled_app(".bundle/config"))
      current = File.exist?(path) ? Psych.load_file(path) : {}
      return current unless config

      current = {} if current.empty?

      FileUtils.mkdir_p(File.dirname(path))

      new_config = current.merge(config).compact

      File.open(path, "w+") do |f|
        f.puts new_config.to_yaml
      end

      new_config
    end

    def global_config(config = nil)
      config(config, home(".bundle/config"))
    end

    def create_file(path, contents = "")
      contents = strip_whitespace(contents)
      path = Pathname.new(path).expand_path(bundled_app) unless path.is_a?(Pathname)
      path.dirname.mkpath
      path.write(contents)

      # if the file is a script, create respective bat file on Windows
      if contents.start_with?("#!")
        path.chmod(0o755)
        if Gem.win_platform?
          path.sub_ext(".bat").write <<~SCRIPT
            @ECHO OFF
            @"ruby.exe" "%~dpn0" %*
          SCRIPT
        end
      end
    end

    def gemfile(*args)
      contents = args.pop

      if contents.nil?
        read_gemfile
      else
        match_source(contents)
        create_file(args.pop || "Gemfile", contents)
      end
    end

    def lockfile(*args)
      contents = args.pop

      if contents.nil?
        read_lockfile
      else
        create_file(args.pop || "Gemfile.lock", contents)
      end
    end

    def read_gemfile(file = "Gemfile")
      read_bundled_app_file(file)
    end

    def read_lockfile(file = "Gemfile.lock")
      read_bundled_app_file(file)
    end

    def read_bundled_app_file(file)
      bundled_app(file).read
    end

    def strip_whitespace(str)
      # Trim the leading spaces
      spaces = str[/\A\s+/, 0] || ""
      str.gsub(/^#{spaces}/, "")
    end

    def install_gemfile(*args)
      opts = args.last.is_a?(Hash) ? args.pop : {}
      gemfile(*args)
      bundle :install, opts
    end

    def lock_gemfile(*args)
      gemfile(*args)
      opts = args.last.is_a?(Hash) ? args.last : {}
      bundle :lock, opts
    end

    def base_system_gems(*names, **options)
      system_gems names.map {|name| find_base_path(name) }, **options
    end

    def system_gems(*gems)
      gems = gems.flatten
      options = gems.last.is_a?(Hash) ? gems.pop : {}
      install_dir = options.fetch(:path, system_gem_path)
      default = options.fetch(:default, false)
      gems.each do |g|
        gem_name = g.to_s
        bundler = gem_name.match(/\Abundler-(?<version>.*)\z/)

        if bundler
          with_built_bundler(bundler[:version], released: options.fetch(:released, false)) {|gem_path| install_gem(gem_path, install_dir, default) }
        elsif %r{\A(?:[a-zA-Z]:)?/.*\.gem\z}.match?(gem_name)
          install_gem(gem_name, install_dir, default)
        else
          gem_repo = options.fetch(:gem_repo, gem_repo1)
          install_gem("#{gem_repo}/gems/#{gem_name}.gem", install_dir, default)
        end
      end
    end

    def self.install_dev_bundler
      extend self

      with_built_bundler(nil, build_path: tmp_root) {|gem_path| install_gem(gem_path, pristine_system_gem_path) }
    end

    def install_gem(path, install_dir, default = false)
      raise "OMG `#{path}` does not exist!" unless File.exist?(path)

      args = "--no-document --ignore-dependencies --verbose --local --install-dir #{install_dir}"
      args += " --default" if default

      gem_command "install #{args} '#{path}'"
    end

    def with_built_bundler(version = nil, opts = {}, &block)
      require_relative "builders"

      Builders::BundlerBuilder.new(self, "bundler", version)._build(opts, &block)
    end

    def with_gem_path_as(path)
      without_env_side_effects do
        ENV["GEM_HOME"] = path.to_s
        ENV["GEM_PATH"] = path.to_s
        ENV["BUNDLER_ORIG_GEM_HOME"] = nil
        ENV["BUNDLER_ORIG_GEM_PATH"] = nil
        yield
      end
    end

    def with_path_as(path)
      without_env_side_effects do
        ENV["PATH"] = path.to_s
        ENV["BUNDLER_ORIG_PATH"] = nil
        yield
      end
    end

    def without_env_side_effects
      backup = ENV.to_hash
      yield
    ensure
      ENV.replace(backup)
    end

    def with_path_added(path)
      with_path_as([path.to_s, ENV["PATH"]].join(File::PATH_SEPARATOR)) do
        yield
      end
    end

    def break_git!
      FileUtils.mkdir_p(tmp("broken_path"))
      File.open(tmp("broken_path/git"), "w", 0o755) do |f|
        f.puts "#!/usr/bin/env ruby\nSTDERR.puts 'This is not the git you are looking for'\nexit 1"
      end

      ENV["PATH"] = "#{tmp("broken_path")}:#{ENV["PATH"]}"
    end

    def with_fake_man
      FileUtils.mkdir_p(tmp("fake_man"))
      create_file(tmp("fake_man/man"), <<~SCRIPT)
        #!/usr/bin/env ruby
        puts ARGV.inspect
      SCRIPT
      with_path_added(tmp("fake_man")) { yield }
    end

    def pristine_system_gems(*gems)
      FileUtils.rm_r(system_gem_path)

      if gems.any?
        system_gems(*gems)
      else
        default_system_gems
      end
    end

    def cache_gems(*gems, gem_repo: gem_repo1)
      gems = gems.flatten

      FileUtils.mkdir_p("#{bundled_app}/vendor/cache")

      gems.each do |g|
        path = "#{gem_repo}/gems/#{g}.gem"
        raise "OMG `#{path}` does not exist!" unless File.exist?(path)
        FileUtils.cp(path, "#{bundled_app}/vendor/cache")
      end
    end

    def simulate_new_machine
      FileUtils.rm_r bundled_app(".bundle")
      pristine_system_gems
    end

    def default_system_gems
      FileUtils.cp_r pristine_system_gem_path, system_gem_path
    end

    def simulate_ruby_platform(ruby_platform)
      old = ENV["BUNDLER_SPEC_RUBY_PLATFORM"]
      ENV["BUNDLER_SPEC_RUBY_PLATFORM"] = ruby_platform.to_s
      yield
    ensure
      ENV["BUNDLER_SPEC_RUBY_PLATFORM"] = old
    end

    def simulate_platform(platform)
      old = ENV["BUNDLER_SPEC_PLATFORM"]
      ENV["BUNDLER_SPEC_PLATFORM"] = platform.to_s
      yield
    ensure
      ENV["BUNDLER_SPEC_PLATFORM"] = old if block_given?
    end

    def current_ruby_minor
      Gem.ruby_version.segments.tap {|s| s.delete_at(2) }.join(".")
    end

    def next_ruby_minor
      ruby_major_minor.map.with_index {|s, i| i == 1 ? s + 1 : s }.join(".")
    end

    def ruby_major_minor
      Gem.ruby_version.segments[0..1]
    end

    def revision_for(path)
      git("rev-parse HEAD", path).strip
    end

    def with_read_only(pattern)
      chmod = lambda do |dirmode, filemode|
        lambda do |f|
          mode = File.directory?(f) ? dirmode : filemode
          File.chmod(mode, f)
        end
      end

      Dir[pattern].each(&chmod[0o555, 0o444])
      yield
    ensure
      Dir[pattern].each(&chmod[0o755, 0o644])
    end

    # Simulate replacing TODOs with real values
    def prepare_gemspec(pathname)
      process_file(pathname) do |line|
        case line
        when /spec\.metadata\["(?:allowed_push_host|homepage_uri|source_code_uri|changelog_uri)"\]/, /spec\.homepage/
          line.gsub(/\=.*$/, '= "http://example.org"')
        when /spec\.summary/
          line.gsub(/\=.*$/, '= "A short summary of my new gem."')
        when /spec\.description/
          line.gsub(/\=.*$/, '= "A longer description of my new gem."')
        else
          line
        end
      end
    end

    def process_file(pathname)
      changed_lines = pathname.readlines.map do |line|
        yield line
      end
      File.open(pathname, "w") {|file| file.puts(changed_lines.join) }
    end

    def with_env_vars(env_hash, &block)
      current_values = {}
      env_hash.each do |k, v|
        current_values[k] = ENV[k]
        ENV[k] = v
      end
      block.call if block_given?
      env_hash.each do |k, _|
        ENV[k] = current_values[k]
      end
    end

    def require_rack_test
      # need to hack, so we can require rack for testing
      old_gem_home = ENV["GEM_HOME"]
      ENV["GEM_HOME"] = Spec::Path.scoped_base_system_gem_path.to_s
      require "rack/test"
      ENV["GEM_HOME"] = old_gem_home
    end

    def exit_status_for_signal(signal_number)
      # For details see: https://en.wikipedia.org/wiki/Exit_status#Shell_and_scripts
      128 + signal_number
    end

    def empty_repo4
      FileUtils.rm_r gem_repo4

      build_repo4 {}
    end

    private

    def allowed_rubygems_warning?(text, extra_allowed_warning)
      allowed_warnings = ["open-ended", "is a symlink", "rake based", "expected RubyGems version"]
      allowed_warnings << extra_allowed_warning if extra_allowed_warning
      allowed_warnings.any? do |warning|
        text.include?(warning)
      end
    end

    def match_source(contents)
      match = /source ["']?(?<source>http[^"']+)["']?/.match(contents)
      return unless match

      @gemfile_source = match[:source]
    end

    def git_root_dir?
      root.to_s == `git rev-parse --show-toplevel`.chomp
    end
  end
end
