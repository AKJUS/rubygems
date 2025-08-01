# frozen_string_literal: true

RSpec.describe "bundle install with specific platforms" do
  let(:google_protobuf) { <<-G }
    source "https://gem.repo2"
    gem "google-protobuf"
  G

  it "locks to the specific darwin platform" do
    simulate_platform "x86_64-darwin-15" do
      setup_multiplatform_gem
      install_gemfile(google_protobuf)
      allow(Bundler::SharedHelpers).to receive(:find_gemfile).and_return(bundled_app_gemfile)
      expect(the_bundle.locked_platforms).to include("universal-darwin")
      expect(the_bundle).to include_gem("google-protobuf 3.0.0.alpha.5.0.5.1 universal-darwin")
      expect(the_bundle.locked_gems.specs.map(&:full_name)).to include(
        "google-protobuf-3.0.0.alpha.5.0.5.1-universal-darwin"
      )
    end
  end

  it "still installs the platform specific variant when locked only to ruby, and the platform specific variant has different dependencies" do
    simulate_platform "x86_64-darwin-15" do
      build_repo4 do
        build_gem("sass-embedded", "1.72.0") do |s|
          s.add_dependency "rake"
        end

        build_gem("sass-embedded", "1.72.0") do |s|
          s.platform = "x86_64-darwin-15"
        end

        build_gem "rake"
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "sass-embedded"
      G

      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            rake (1.0)
            sass-embedded (1.72.0)
              rake

        PLATFORMS
          ruby

        DEPENDENCIES
          sass-embedded

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "install --verbose"
      expect(err).to include("The following platform specific gems are getting installed, yet the lockfile includes only their generic ruby version")
      expect(out).to include("Installing sass-embedded 1.72.0 (x86_64-darwin-15)")

      expect(the_bundle).to include_gem("sass-embedded 1.72.0 x86_64-darwin-15")
    end
  end

  it "understands that a non-platform specific gem in a old lockfile doesn't necessarily mean installing the non-specific variant" do
    simulate_platform "x86_64-darwin-15" do
      setup_multiplatform_gem

      # Consistent location to install and look for gems
      bundle "config set --local path vendor/bundle"

      install_gemfile(google_protobuf)

      # simulate lockfile created with old bundler, which only locks for ruby platform
      lockfile <<-L
        GEM
          remote: https://gem.repo2/
          specs:
            google-protobuf (3.0.0.alpha.5.0.5.1)

        PLATFORMS
          ruby

        DEPENDENCIES
          google-protobuf

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      # force strict usage of the lockfile by setting frozen mode
      bundle "config set --local frozen true"

      # make sure the platform that got actually installed with the old bundler is used
      expect(the_bundle).to include_gem("google-protobuf 3.0.0.alpha.5.0.5.1 universal-darwin")
    end
  end

  it "understands that a non-platform specific gem in a new lockfile locked only to ruby doesn't necessarily mean installing the non-specific variant" do
    simulate_platform "x86_64-darwin-15" do
      setup_multiplatform_gem

      # Consistent location to install and look for gems
      bundle "config set --local path vendor/bundle"

      gemfile google_protobuf

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo2, "google-protobuf", "3.0.0.alpha.4.0"
      end

      # simulate lockfile created with old bundler, which only locks for ruby platform
      lockfile <<-L
        GEM
          remote: https://gem.repo2/
          specs:
            google-protobuf (3.0.0.alpha.4.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          google-protobuf
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "update"
      expect(err).to include("The following platform specific gems are getting installed, yet the lockfile includes only their generic ruby version")

      checksums.checksum gem_repo2, "google-protobuf", "3.0.0.alpha.5.0.5.1"

      # make sure the platform that the platform specific dependency is used, since we're only locked to ruby
      expect(the_bundle).to include_gem("google-protobuf 3.0.0.alpha.5.0.5.1 universal-darwin")

      # make sure we're still only locked to ruby
      expect(lockfile).to eq <<~L
        GEM
          remote: https://gem.repo2/
          specs:
            google-protobuf (3.0.0.alpha.5.0.5.1)

        PLATFORMS
          ruby

        DEPENDENCIES
          google-protobuf
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  context "when running on a legacy lockfile locked only to ruby" do
    around do |example|
      build_repo4 do
        build_gem "nokogiri", "1.3.10"
        build_gem "nokogiri", "1.3.10" do |s|
          s.platform = "arm64-darwin"
          s.required_ruby_version = "< #{Gem.ruby_version}"
        end
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri"
      G

      lockfile <<-L
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.3.10)

        PLATFORMS
          ruby

        DEPENDENCIES
          nokogiri

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      simulate_platform "arm64-darwin-22", &example
    end

    it "still installs the generic ruby variant if necessary" do
      bundle "install --verbose"
      expect(out).to include("Installing nokogiri 1.3.10")
    end

    it "still installs the generic ruby variant if necessary, even in frozen mode" do
      bundle "install --verbose", env: { "BUNDLE_FROZEN" => "true" }
      expect(out).to include("Installing nokogiri 1.3.10")
    end
  end

  it "doesn't discard previously installed platform specific gem and fall back to ruby on subsequent bundles" do
    simulate_platform "x86_64-darwin-15" do
      build_repo2 do
        build_gem("libv8", "8.4.255.0")
        build_gem("libv8", "8.4.255.0") {|s| s.platform = "universal-darwin" }

        build_gem("mini_racer", "1.0.0") do |s|
          s.add_dependency "libv8"
        end
      end

      # Consistent location to install and look for gems
      bundle "config set --local path vendor/bundle"

      gemfile <<-G
        source "https://gem.repo2"
        gem "libv8"
      G

      # simulate lockfile created with old bundler, which only locks for ruby platform
      lockfile <<-L
        GEM
          remote: https://gem.repo2/
          specs:
            libv8 (8.4.255.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          libv8

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "install --verbose"
      expect(err).to include("The following platform specific gems are getting installed, yet the lockfile includes only their generic ruby version")
      expect(out).to include("Installing libv8 8.4.255.0 (universal-darwin)")

      bundle "add mini_racer --verbose"
      expect(out).to include("Using libv8 8.4.255.0 (universal-darwin)")
    end
  end

  it "chooses platform specific gems even when resolving upon materialization and the API returns more specific platforms first" do
    simulate_platform "x86_64-darwin-15" do
      build_repo4 do
        build_gem("grpc", "1.50.0")
        build_gem("grpc", "1.50.0") {|s| s.platform = "universal-darwin" }
      end

      gemfile <<-G
        source "https://gem.repo4"
        gem "grpc"
      G

      # simulate lockfile created with old bundler, which only locks for ruby platform
      lockfile <<-L
        GEM
          remote: https://gem.repo4/
          specs:
            grpc (1.50.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          grpc

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "install --verbose", artifice: "compact_index_precompiled_before"
      expect(err).to include("The following platform specific gems are getting installed, yet the lockfile includes only their generic ruby version")
      expect(out).to include("Installing grpc 1.50.0 (universal-darwin)")
    end
  end

  it "caches the universal-darwin gem when --all-platforms is passed and properly picks it up on further bundler invocations" do
    simulate_platform "x86_64-darwin-15" do
      setup_multiplatform_gem
      gemfile(google_protobuf)
      bundle "cache --all-platforms"
      expect(cached_gem("google-protobuf-3.0.0.alpha.5.0.5.1-universal-darwin")).to exist

      bundle "install --verbose"
      expect(err).to be_empty
    end
  end

  it "caches the universal-darwin gem when cache_all_platforms is configured and properly picks it up on further bundler invocations" do
    simulate_platform "x86_64-darwin-15" do
      setup_multiplatform_gem
      gemfile(google_protobuf)
      bundle "config set --local cache_all_platforms true"
      bundle "cache"
      expect(cached_gem("google-protobuf-3.0.0.alpha.5.0.5.1-universal-darwin")).to exist

      bundle "install --verbose"
      expect(err).to be_empty
    end
  end

  it "caches multiplatform git gems with a single gemspec when --all-platforms is passed" do
    git = build_git "pg_array_parser", "1.0"

    gemfile <<-G
      source "https://gem.repo1"
      gem "pg_array_parser", :git => "#{lib_path("pg_array_parser-1.0")}"
    G

    lockfile <<-L
      GIT
        remote: #{lib_path("pg_array_parser-1.0")}
        revision: #{git.ref_for("main")}
        specs:
          pg_array_parser (1.0-java)
          pg_array_parser (1.0)

      GEM
        specs:

      PLATFORMS
        #{lockfile_platforms("java")}

      DEPENDENCIES
        pg_array_parser!

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    bundle "config set --local cache_all true"
    bundle "cache --all-platforms"

    expect(err).to be_empty
  end

  it "uses the platform-specific gem with extra dependencies" do
    simulate_platform "x86_64-darwin-15" do
      setup_multiplatform_gem_with_different_dependencies_per_platform
      install_gemfile <<-G
        source "https://gem.repo2"
        gem "facter"
      G
      allow(Bundler::SharedHelpers).to receive(:find_gemfile).and_return(bundled_app_gemfile)

      expect(the_bundle.locked_platforms).to include("universal-darwin")
      expect(the_bundle).to include_gems("facter 2.4.6 universal-darwin", "CFPropertyList 1.0")
      expect(the_bundle.locked_gems.specs.map(&:full_name)).to include("CFPropertyList-1.0",
                                                                       "facter-2.4.6-universal-darwin")
    end
  end

  context "when adding a platform via lock --add_platform" do
    before do
      allow(Bundler::SharedHelpers).to receive(:find_gemfile).and_return(bundled_app_gemfile)
    end

    it "adds the foreign platform" do
      simulate_platform "x86_64-darwin-15" do
        setup_multiplatform_gem
        install_gemfile(google_protobuf)
        bundle "lock --add-platform=x64-mingw-ucrt"

        expect(the_bundle.locked_platforms).to include("x64-mingw-ucrt", "universal-darwin")
        expect(the_bundle.locked_gems.specs.map(&:full_name)).to include(*%w[
          google-protobuf-3.0.0.alpha.5.0.5.1-universal-darwin
          google-protobuf-3.0.0.alpha.5.0.5.1-x64-mingw-ucrt
        ])
      end
    end

    it "falls back on plain ruby when that version doesn't have a platform-specific gem" do
      simulate_platform "x86_64-darwin-15" do
        setup_multiplatform_gem
        install_gemfile(google_protobuf)
        bundle "lock --add-platform=java"

        expect(the_bundle.locked_platforms).to include("java", "universal-darwin")
        expect(the_bundle.locked_gems.specs.map(&:full_name)).to include(
          "google-protobuf-3.0.0.alpha.5.0.5.1",
          "google-protobuf-3.0.0.alpha.5.0.5.1-universal-darwin"
        )
      end
    end
  end

  it "installs sorbet-static, which does not provide a pure ruby variant, in absence of a lockfile, just fine", :truffleruby do
    skip "does not apply to Windows" if Gem.win_platform?

    build_repo2 do
      build_gem("sorbet-static", "0.5.6403") {|s| s.platform = Bundler.local_platform }
    end

    gemfile <<~G
      source "https://gem.repo2"

      gem "sorbet-static", "0.5.6403"
    G

    bundle "install --verbose"
  end

  it "installs sorbet-static, which does not provide a pure ruby variant, in presence of a lockfile, just fine", :truffleruby do
    skip "does not apply to Windows" if Gem.win_platform?

    build_repo2 do
      build_gem("sorbet-static", "0.5.6403") {|s| s.platform = Bundler.local_platform }
    end

    gemfile <<~G
      source "https://gem.repo2"

      gem "sorbet-static", "0.5.6403"
    G

    lockfile <<~L
      GEM
        remote: https://gem.repo2/
        specs:
          sorbet-static (0.5.6403-#{Bundler.local_platform})

      PLATFORMS
        ruby

      DEPENDENCIES
        sorbet-static (= 0.5.6403)

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    bundle "install --verbose"
  end

  it "does not resolve if the current platform does not match any of available platform specific variants for a top level dependency" do
    build_repo4 do
      build_gem("sorbet-static", "0.5.6433") {|s| s.platform = "x86_64-linux" }
      build_gem("sorbet-static", "0.5.6433") {|s| s.platform = "universal-darwin-20" }
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "sorbet-static", "0.5.6433"
    G

    error_message = <<~ERROR.strip
      Could not find gem 'sorbet-static (= 0.5.6433)' with platform 'arm64-darwin-21' in rubygems repository https://gem.repo4/ or installed locally.

      The source contains the following gems matching 'sorbet-static (= 0.5.6433)':
        * sorbet-static-0.5.6433-universal-darwin-20
        * sorbet-static-0.5.6433-x86_64-linux
    ERROR

    simulate_platform "arm64-darwin-21" do
      bundle "lock", raise_on_error: false
    end

    expect(err).to include(error_message).once

    # Make sure it doesn't print error twice in verbose mode

    simulate_platform "arm64-darwin-21" do
      bundle "lock --verbose", raise_on_error: false
    end

    expect(err).to include(error_message).once
  end

  it "does not resolve if the current platform does not match any of available platform specific variants for a transitive dependency" do
    build_repo4 do
      build_gem("sorbet", "0.5.6433") {|s| s.add_dependency "sorbet-static", "= 0.5.6433" }
      build_gem("sorbet-static", "0.5.6433") {|s| s.platform = "x86_64-linux" }
      build_gem("sorbet-static", "0.5.6433") {|s| s.platform = "universal-darwin-20" }
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "sorbet", "0.5.6433"
    G

    error_message = <<~ERROR.strip
      Could not find compatible versions

      Because every version of sorbet depends on sorbet-static = 0.5.6433
        and sorbet-static = 0.5.6433 could not be found in rubygems repository https://gem.repo4/ or installed locally for any resolution platforms (arm64-darwin-21),
        sorbet cannot be used.
      So, because Gemfile depends on sorbet = 0.5.6433,
        version solving has failed.

      The source contains the following gems matching 'sorbet-static (= 0.5.6433)':
        * sorbet-static-0.5.6433-universal-darwin-20
        * sorbet-static-0.5.6433-x86_64-linux
    ERROR

    simulate_platform "arm64-darwin-21" do
      bundle "lock", raise_on_error: false
    end

    expect(err).to include(error_message).once

    # Make sure it doesn't print error twice in verbose mode

    simulate_platform "arm64-darwin-21" do
      bundle "lock --verbose", raise_on_error: false
    end

    expect(err).to include(error_message).once
  end

  it "does not generate a lockfile if ruby platform is forced and some gem has no ruby variant available" do
    build_repo4 do
      build_gem("sorbet-static", "0.5.9889") {|s| s.platform = Gem::Platform.local }
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "sorbet-static", "0.5.9889"
    G

    bundle "lock", raise_on_error: false, env: { "BUNDLE_FORCE_RUBY_PLATFORM" => "true" }

    expect(err).to include <<~ERROR.rstrip
      Could not find gem 'sorbet-static (= 0.5.9889)' with platform 'ruby' in rubygems repository https://gem.repo4/ or installed locally.

      The source contains the following gems matching 'sorbet-static (= 0.5.9889)':
        * sorbet-static-0.5.9889-#{Gem::Platform.local}
    ERROR
  end

  it "automatically fixes the lockfile if ruby platform is locked and some gem has no ruby variant available" do
    build_repo4 do
      build_gem("sorbet-static-and-runtime", "0.5.10160") do |s|
        s.add_dependency "sorbet", "= 0.5.10160"
        s.add_dependency "sorbet-runtime", "= 0.5.10160"
      end

      build_gem("sorbet", "0.5.10160") do |s|
        s.add_dependency "sorbet-static", "= 0.5.10160"
      end

      build_gem("sorbet-runtime", "0.5.10160")

      build_gem("sorbet-static", "0.5.10160") do |s|
        s.platform = Gem::Platform.local
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "sorbet-static-and-runtime"
    G

    lockfile <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          sorbet (0.5.10160)
            sorbet-static (= 0.5.10160)
          sorbet-runtime (0.5.10160)
          sorbet-static (0.5.10160-#{Gem::Platform.local})
          sorbet-static-and-runtime (0.5.10160)
            sorbet (= 0.5.10160)
            sorbet-runtime (= 0.5.10160)

      PLATFORMS
        #{lockfile_platforms}

      DEPENDENCIES
        sorbet-static-and-runtime

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    bundle "update"

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "sorbet", "0.5.10160"
      c.checksum gem_repo4, "sorbet-runtime", "0.5.10160"
      c.checksum gem_repo4, "sorbet-static", "0.5.10160", Gem::Platform.local
      c.checksum gem_repo4, "sorbet-static-and-runtime", "0.5.10160"
    end

    expect(lockfile).to eq <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          sorbet (0.5.10160)
            sorbet-static (= 0.5.10160)
          sorbet-runtime (0.5.10160)
          sorbet-static (0.5.10160-#{Gem::Platform.local})
          sorbet-static-and-runtime (0.5.10160)
            sorbet (= 0.5.10160)
            sorbet-runtime (= 0.5.10160)

      PLATFORMS
        #{local_platform}

      DEPENDENCIES
        sorbet-static-and-runtime
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L
  end

  it "automatically fixes the lockfile if both ruby platform and a more specific platform are locked, and some gem has no ruby variant available" do
    build_repo4 do
      build_gem "nokogiri", "1.12.0"
      build_gem "nokogiri", "1.12.0" do |s|
        s.platform = "x86_64-darwin"
      end

      build_gem "nokogiri", "1.13.0"
      build_gem "nokogiri", "1.13.0" do |s|
        s.platform = "x86_64-darwin"
      end

      build_gem("sorbet-static", "0.5.10601") do |s|
        s.platform = "x86_64-darwin"
      end
    end

    simulate_platform "x86_64-darwin-22" do
      install_gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri"
        gem "sorbet-static"
      G
    end

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "nokogiri", "1.13.0", "x86_64-darwin"
      c.checksum gem_repo4, "sorbet-static", "0.5.10601", "x86_64-darwin"
    end

    lockfile <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          nokogiri (1.12.0)
          nokogiri (1.12.0-x86_64-darwin)
          sorbet-static (0.5.10601-x86_64-darwin)

      PLATFORMS
        ruby
        x86_64-darwin

      DEPENDENCIES
        nokogiri
        sorbet-static
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L

    simulate_platform "x86_64-darwin-22" do
      bundle "update --conservative nokogiri"
    end

    expect(lockfile).to eq <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          nokogiri (1.13.0-x86_64-darwin)
          sorbet-static (0.5.10601-x86_64-darwin)

      PLATFORMS
        x86_64-darwin

      DEPENDENCIES
        nokogiri
        sorbet-static
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L
  end

  it "automatically fixes the lockfile if only ruby platform is locked and some gem has no ruby variant available" do
    build_repo4 do
      build_gem("sorbet-static-and-runtime", "0.5.10160") do |s|
        s.add_dependency "sorbet", "= 0.5.10160"
        s.add_dependency "sorbet-runtime", "= 0.5.10160"
      end

      build_gem("sorbet", "0.5.10160") do |s|
        s.add_dependency "sorbet-static", "= 0.5.10160"
      end

      build_gem("sorbet-runtime", "0.5.10160")

      build_gem("sorbet-static", "0.5.10160") do |s|
        s.platform = Gem::Platform.local
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "sorbet-static-and-runtime"
    G

    lockfile <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          sorbet (0.5.10160)
            sorbet-static (= 0.5.10160)
          sorbet-runtime (0.5.10160)
          sorbet-static (0.5.10160-#{Gem::Platform.local})
          sorbet-static-and-runtime (0.5.10160)
            sorbet (= 0.5.10160)
            sorbet-runtime (= 0.5.10160)

      PLATFORMS
        ruby

      DEPENDENCIES
        sorbet-static-and-runtime

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    bundle "update"

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "sorbet", "0.5.10160"
      c.checksum gem_repo4, "sorbet-runtime", "0.5.10160"
      c.checksum gem_repo4, "sorbet-static", "0.5.10160", Gem::Platform.local
      c.checksum gem_repo4, "sorbet-static-and-runtime", "0.5.10160"
    end

    expect(lockfile).to eq <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          sorbet (0.5.10160)
            sorbet-static (= 0.5.10160)
          sorbet-runtime (0.5.10160)
          sorbet-static (0.5.10160-#{Gem::Platform.local})
          sorbet-static-and-runtime (0.5.10160)
            sorbet (= 0.5.10160)
            sorbet-runtime (= 0.5.10160)

      PLATFORMS
        #{local_platform}

      DEPENDENCIES
        sorbet-static-and-runtime
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L
  end

  it "automatically fixes the lockfile when adding a gem that introduces dependencies with no ruby platform variants transitively" do
    simulate_platform "x86_64-linux" do
      build_repo4 do
        build_gem "nokogiri", "1.18.2"

        build_gem "nokogiri", "1.18.2" do |s|
          s.platform = "x86_64-linux"
        end

        build_gem("sorbet", "0.5.11835") do |s|
          s.add_dependency "sorbet-static", "= 0.5.11835"
        end

        build_gem "sorbet-static", "0.5.11835" do |s|
          s.platform = "x86_64-linux"
        end
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri"
        gem "sorbet"
      G

      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.18.2)
            nokogiri (1.18.2-x86_64-linux)

        PLATFORMS
          ruby
          x86_64-linux

        DEPENDENCIES
          nokogiri

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "lock"

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "nokogiri", "1.18.2", "x86_64-linux"
        c.checksum gem_repo4, "sorbet", "0.5.11835"
        c.checksum gem_repo4, "sorbet-static", "0.5.11835", "x86_64-linux"
      end

      expect(lockfile).to eq <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.18.2)
            nokogiri (1.18.2-x86_64-linux)
            sorbet (0.5.11835)
              sorbet-static (= 0.5.11835)
            sorbet-static (0.5.11835-x86_64-linux)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          nokogiri
          sorbet
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "automatically fixes the lockfile if multiple platforms locked, but no valid versions of direct dependencies for all of them" do
    simulate_platform "x86_64-linux" do
      build_repo4 do
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "x86_64-linux"
        end
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "arm-linux"
        end

        build_gem "sorbet-static", "0.5.10696" do |s|
          s.platform = "x86_64-linux"
        end
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri"
        gem "sorbet-static"
      G

      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.14.0-arm-linux)
            nokogiri (1.14.0-x86_64-linux)
            sorbet-static (0.5.10696-x86_64-linux)

        PLATFORMS
          aarch64-linux
          arm-linux
          x86_64-linux

        DEPENDENCIES
          nokogiri
          sorbet-static

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "update"

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "nokogiri", "1.14.0", "x86_64-linux"
        c.checksum gem_repo4, "sorbet-static", "0.5.10696", "x86_64-linux"
      end

      expect(lockfile).to eq <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.14.0-x86_64-linux)
            sorbet-static (0.5.10696-x86_64-linux)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          nokogiri
          sorbet-static
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "automatically fixes the lockfile without removing other variants if it's missing platform gems, but they are installed locally" do
    simulate_platform "x86_64-darwin-21" do
      build_repo4 do
        build_gem("sorbet-static", "0.5.10549") do |s|
          s.platform = "universal-darwin-20"
        end

        build_gem("sorbet-static", "0.5.10549") do |s|
          s.platform = "universal-darwin-21"
        end
      end

      # Make sure sorbet-static-0.5.10549-universal-darwin-21 is installed
      install_gemfile <<~G
        source "https://gem.repo4"

        gem "sorbet-static", "= 0.5.10549"
      G

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "sorbet-static", "0.5.10549", "universal-darwin-20"
        c.checksum gem_repo4, "sorbet-static", "0.5.10549", "universal-darwin-21"
      end

      # Make sure the lockfile is missing sorbet-static-0.5.10549-universal-darwin-21
      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            sorbet-static (0.5.10549-universal-darwin-20)

        PLATFORMS
          x86_64-darwin

        DEPENDENCIES
          sorbet-static (= 0.5.10549)
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "install"

      expect(lockfile).to eq <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            sorbet-static (0.5.10549-universal-darwin-20)
            sorbet-static (0.5.10549-universal-darwin-21)

        PLATFORMS
          x86_64-darwin

        DEPENDENCIES
          sorbet-static (= 0.5.10549)
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "automatically fixes the lockfile if locked only to ruby, and some locked specs don't meet locked dependencies" do
    simulate_platform "x86_64-linux" do
      build_repo4 do
        build_gem("ibandit", "0.7.0") do |s|
          s.add_dependency "i18n", "~> 0.7.0"
        end

        build_gem("i18n", "0.7.0.beta1")
        build_gem("i18n", "0.7.0")
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "ibandit", "~> 0.7.0"
      G

      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            i18n (0.7.0.beta1)
            ibandit (0.7.0)
              i18n (~> 0.7.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          ibandit (~> 0.7.0)

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "lock --update i18n"

      expect(lockfile).to eq <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            i18n (0.7.0)
            ibandit (0.7.0)
              i18n (~> 0.7.0)

        PLATFORMS
          ruby

        DEPENDENCIES
          ibandit (~> 0.7.0)

        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "does not remove ruby if gems for other platforms, and not present in the lockfile, exist in the Gemfile" do
    build_repo4 do
      build_gem "nokogiri", "1.13.8"
      build_gem "nokogiri", "1.13.8" do |s|
        s.platform = Gem::Platform.local
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "nokogiri"

      gem "tzinfo", "~> 1.2", platform: :#{not_local_tag}
    G

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "nokogiri", "1.13.8"
      c.checksum gem_repo4, "nokogiri", "1.13.8", Gem::Platform.local
    end

    original_lockfile = <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          nokogiri (1.13.8)
          nokogiri (1.13.8-#{Gem::Platform.local})

      PLATFORMS
        #{lockfile_platforms("ruby")}

      DEPENDENCIES
        nokogiri
        tzinfo (~> 1.2)
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L

    lockfile original_lockfile

    bundle "lock --update"

    expect(lockfile).to eq(original_lockfile)
  end

  it "does not remove ruby if gems for other platforms, and not present in the lockfile, exist in the Gemfile, and the lockfile only has ruby" do
    build_repo4 do
      build_gem "nokogiri", "1.13.8"
      build_gem "nokogiri", "1.13.8" do |s|
        s.platform = "arm64-darwin"
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "nokogiri"

      gem "tzinfo", "~> 1.2", platforms: %i[windows jruby]
    G

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "nokogiri", "1.13.8"
    end

    original_lockfile = <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          nokogiri (1.13.8)

      PLATFORMS
        ruby

      DEPENDENCIES
        nokogiri
        tzinfo (~> 1.2)
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L

    lockfile original_lockfile

    simulate_platform "arm64-darwin-23" do
      bundle "lock --update"
    end

    expect(lockfile).to eq(original_lockfile)
  end

  it "does not remove ruby when adding a new gem to the Gemfile" do
    build_repo4 do
      build_gem "concurrent-ruby", "1.2.2"
      build_gem "myrack", "3.0.7"
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "concurrent-ruby"
      gem "myrack"
    G

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "concurrent-ruby", "1.2.2"
      c.checksum gem_repo4, "myrack", "3.0.7"
    end

    lockfile <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          concurrent-ruby (1.2.2)

      PLATFORMS
        ruby

      DEPENDENCIES
        concurrent-ruby
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L

    bundle "lock"

    expect(lockfile).to eq <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          concurrent-ruby (1.2.2)
          myrack (3.0.7)

      PLATFORMS
        #{lockfile_platforms(generic_default_locked_platform || local_platform, defaults: ["ruby"])}

      DEPENDENCIES
        concurrent-ruby
        myrack
      #{checksums}
      BUNDLED WITH
         #{Bundler::VERSION}
    L
  end

  it "can fallback to a source gem when platform gems are incompatible with current ruby version" do
    setup_multiplatform_gem_with_source_gem

    gemfile <<~G
      source "https://gem.repo2"

      gem "my-precompiled-gem"
    G

    # simulate lockfile which includes both a precompiled gem with:
    # - Gem the current platform (with incompatible ruby version)
    # - A source gem with compatible ruby version
    lockfile <<-L
      GEM
        remote: https://gem.repo2/
        specs:
          my-precompiled-gem (3.0.0)
          my-precompiled-gem (3.0.0-#{Bundler.local_platform})

      PLATFORMS
        ruby
        #{Bundler.local_platform}

      DEPENDENCIES
        my-precompiled-gem

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    bundle :install
  end

  it "automatically adds the ruby variant to the lockfile if the specific platform is locked and we move to a newer ruby version for which a native package is not available" do
    #
    # Given an existing application using native gems (e.g., nokogiri)
    # And a lockfile generated with a stable ruby version
    # When want test the application against ruby-head and `bundle install`
    # Then bundler should fall back to the generic ruby platform gem
    #
    simulate_platform "x86_64-linux" do
      build_repo4 do
        build_gem "nokogiri", "1.14.0"
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "x86_64-linux"
          s.required_ruby_version = "< #{Gem.ruby_version}"
        end
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri", "1.14.0"
      G

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "nokogiri", "1.14.0", "x86_64-linux"
      end

      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.14.0-x86_64-linux)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          nokogiri (= 1.14.0)
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle :install

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "nokogiri", "1.14.0"
        c.checksum gem_repo4, "nokogiri", "1.14.0", "x86_64-linux"
      end

      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.14.0)
            nokogiri (1.14.0-x86_64-linux)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          nokogiri (= 1.14.0)
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "automatically fixes the lockfile when only ruby platform locked, and adding a dependency with subdependencies not valid for ruby" do
    simulate_platform "x86_64-linux" do
      build_repo4 do
        build_gem("sorbet", "0.5.10160") do |s|
          s.add_dependency "sorbet-static", "= 0.5.10160"
        end

        build_gem("sorbet-static", "0.5.10160") do |s|
          s.platform = "x86_64-linux"
        end
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "sorbet"
      G

      lockfile <<~L
        GEM
          remote: https://gem.repo4/
          specs:

        PLATFORMS
          ruby

        DEPENDENCIES

        BUNDLED WITH
           #{Bundler::VERSION}
      L

      bundle "lock"

      expect(lockfile).to eq <<~L
        GEM
          remote: https://gem.repo4/
          specs:
            sorbet (0.5.10160)
              sorbet-static (= 0.5.10160)
            sorbet-static (0.5.10160-x86_64-linux)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          sorbet

        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "locks specific platforms automatically" do
    simulate_platform "x86_64-linux" do
      build_repo4 do
        build_gem "nokogiri", "1.14.0"
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "x86_64-linux"
        end
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "arm-linux"
        end
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "x64-mingw-ucrt"
        end
        build_gem "nokogiri", "1.14.0" do |s|
          s.platform = "java"
        end

        build_gem "sorbet-static", "0.5.10696" do |s|
          s.platform = "x86_64-linux"
        end
        build_gem "sorbet-static", "0.5.10696" do |s|
          s.platform = "universal-darwin-22"
        end
      end

      gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri"
      G

      bundle "lock"

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "nokogiri", "1.14.0"
        c.checksum gem_repo4, "nokogiri", "1.14.0", "arm-linux"
        c.checksum gem_repo4, "nokogiri", "1.14.0", "x86_64-linux"
      end

      # locks all compatible platforms, excluding Java and Windows
      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.14.0)
            nokogiri (1.14.0-arm-linux)
            nokogiri (1.14.0-x86_64-linux)

        PLATFORMS
          arm-linux
          ruby
          x86_64-linux

        DEPENDENCIES
          nokogiri
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L

      gemfile <<~G
        source "https://gem.repo4"

        gem "nokogiri"
        gem "sorbet-static"
      G

      FileUtils.rm bundled_app_lock

      bundle "lock"

      checksums.delete "nokogiri", "arm-linux"
      checksums.checksum gem_repo4, "sorbet-static", "0.5.10696", "universal-darwin-22"
      checksums.checksum gem_repo4, "sorbet-static", "0.5.10696", "x86_64-linux"

      # locks only platforms compatible with all gems in the bundle
      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.14.0)
            nokogiri (1.14.0-x86_64-linux)
            sorbet-static (0.5.10696-universal-darwin-22)
            sorbet-static (0.5.10696-x86_64-linux)

        PLATFORMS
          universal-darwin-22
          x86_64-linux

        DEPENDENCIES
          nokogiri
          sorbet-static
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "does not fail when a platform variant is incompatible with the current ruby and another equivalent platform specific variant is part of the resolution", rubygems: ">= 3.3.21" do
    build_repo4 do
      build_gem "nokogiri", "1.15.5"

      build_gem "nokogiri", "1.15.5" do |s|
        s.platform = "x86_64-linux"
        s.required_ruby_version = "< #{current_ruby_minor}.dev"
      end

      build_gem "sass-embedded", "1.69.5"

      build_gem "sass-embedded", "1.69.5" do |s|
        s.platform = "x86_64-linux-gnu"
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "nokogiri"
      gem "sass-embedded"
    G

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "nokogiri", "1.15.5"
      c.checksum gem_repo4, "sass-embedded", "1.69.5"
      c.checksum gem_repo4, "sass-embedded", "1.69.5", "x86_64-linux-gnu"
    end

    simulate_platform "x86_64-linux" do
      bundle "install --verbose"

      # locks all compatible platforms, excluding Java and Windows
      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.15.5)
            sass-embedded (1.69.5)
            sass-embedded (1.69.5-x86_64-linux-gnu)

        PLATFORMS
          ruby
          x86_64-linux

        DEPENDENCIES
          nokogiri
          sass-embedded
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "does not add ruby platform gem if it brings extra dependencies not resolved originally" do
    build_repo4 do
      build_gem "nokogiri", "1.15.5" do |s|
        s.add_dependency "mini_portile2", "~> 2.8.2"
      end

      build_gem "nokogiri", "1.15.5" do |s|
        s.platform = "x86_64-linux"
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "nokogiri"
    G

    checksums = checksums_section_when_enabled do |c|
      c.checksum gem_repo4, "nokogiri", "1.15.5", "x86_64-linux"
    end

    simulate_platform "x86_64-linux" do
      bundle "install --verbose"

      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            nokogiri (1.15.5-x86_64-linux)

        PLATFORMS
          x86_64-linux

        DEPENDENCIES
          nokogiri
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  ["x86_64-linux", "x86_64-linux-musl"].each do |host_platform|
    describe "on host platform #{host_platform}" do
      it "adds current musl platform" do
        build_repo4 do
          build_gem "rcee_precompiled", "0.5.0" do |s|
            s.platform = "x86_64-linux"
          end

          build_gem "rcee_precompiled", "0.5.0" do |s|
            s.platform = "x86_64-linux-musl"
          end
        end

        gemfile <<~G
          source "https://gem.repo4"

          gem "rcee_precompiled", "0.5.0"
        G

        simulate_platform host_platform do
          bundle "lock"

          checksums = checksums_section_when_enabled do |c|
            c.checksum gem_repo4, "rcee_precompiled", "0.5.0", "x86_64-linux"
            c.checksum gem_repo4, "rcee_precompiled", "0.5.0", "x86_64-linux-musl"
          end

          expect(lockfile).to eq(<<~L)
            GEM
              remote: https://gem.repo4/
              specs:
                rcee_precompiled (0.5.0-x86_64-linux)
                rcee_precompiled (0.5.0-x86_64-linux-musl)

            PLATFORMS
              x86_64-linux
              x86_64-linux-musl

            DEPENDENCIES
              rcee_precompiled (= 0.5.0)
            #{checksums}
            BUNDLED WITH
               #{Bundler::VERSION}
          L
        end
      end
    end
  end

  it "adds current musl platform, when there are also gnu variants", rubygems: ">= 3.3.21" do
    build_repo4 do
      build_gem "rcee_precompiled", "0.5.0" do |s|
        s.platform = "x86_64-linux-gnu"
      end

      build_gem "rcee_precompiled", "0.5.0" do |s|
        s.platform = "x86_64-linux-musl"
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "rcee_precompiled", "0.5.0"
    G

    simulate_platform "x86_64-linux-musl" do
      bundle "lock"

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "rcee_precompiled", "0.5.0", "x86_64-linux-gnu"
        c.checksum gem_repo4, "rcee_precompiled", "0.5.0", "x86_64-linux-musl"
      end

      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            rcee_precompiled (0.5.0-x86_64-linux-gnu)
            rcee_precompiled (0.5.0-x86_64-linux-musl)

        PLATFORMS
          x86_64-linux-gnu
          x86_64-linux-musl

        DEPENDENCIES
          rcee_precompiled (= 0.5.0)
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "does not add current platform if there's an equivalent less specific platform among the ones resolved" do
    build_repo4 do
      build_gem "rcee_precompiled", "0.5.0" do |s|
        s.platform = "universal-darwin"
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "rcee_precompiled", "0.5.0"
    G

    simulate_platform "x86_64-darwin-15" do
      bundle "lock"

      checksums = checksums_section_when_enabled do |c|
        c.checksum gem_repo4, "rcee_precompiled", "0.5.0", "universal-darwin"
      end

      expect(lockfile).to eq(<<~L)
        GEM
          remote: https://gem.repo4/
          specs:
            rcee_precompiled (0.5.0-universal-darwin)

        PLATFORMS
          universal-darwin

        DEPENDENCIES
          rcee_precompiled (= 0.5.0)
        #{checksums}
        BUNDLED WITH
           #{Bundler::VERSION}
      L
    end
  end

  it "does not re-resolve when a specific platform, but less specific than the current platform, is locked" do
    build_repo4 do
      build_gem "nokogiri"
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "nokogiri"
    G

    lockfile <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          nokogiri (1.0)

      PLATFORMS
        arm64-darwin

      DEPENDENCIES
        nokogiri!

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    simulate_platform "arm64-darwin-23" do
      bundle "install --verbose"

      expect(out).to include("Found no changes, using resolution from the lockfile")
    end
  end

  it "does not remove generic platform gems locked for a specific platform from lockfile when unlocking an unrelated gem" do
    build_repo4 do
      build_gem "ffi"

      build_gem "ffi" do |s|
        s.platform = "x86_64-linux"
      end

      build_gem "nokogiri"
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "ffi"
      gem "nokogiri"
    G

    original_lockfile = <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          ffi (1.0)
          nokogiri (1.0)

      PLATFORMS
        x86_64-linux

      DEPENDENCIES
        ffi
        nokogiri

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    lockfile original_lockfile

    simulate_platform "x86_64-linux" do
      bundle "lock --update nokogiri"

      expect(lockfile).to eq(original_lockfile)
    end
  end

  it "does not remove generic platform gems locked for a specific platform from lockfile when unlocking an unrelated gem, and variants for other platform also locked" do
    build_repo4 do
      build_gem "ffi"

      build_gem "ffi" do |s|
        s.platform = "x86_64-linux"
      end

      build_gem "ffi" do |s|
        s.platform = "java"
      end

      build_gem "nokogiri"
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "ffi"
      gem "nokogiri"
    G

    original_lockfile = <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          ffi (1.0)
          ffi (1.0-java)
          nokogiri (1.0)

      PLATFORMS
        java
        x86_64-linux

      DEPENDENCIES
        ffi
        nokogiri

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    lockfile original_lockfile

    simulate_platform "x86_64-linux" do
      bundle "lock --update nokogiri"

      expect(lockfile).to eq(original_lockfile)
    end
  end

  it "does not remove platform specific gems from lockfile when using a ruby version that does not match their ruby requirements, since they may be useful in other rubies" do
    build_repo4 do
      build_gem("google-protobuf", "3.25.5")
      build_gem("google-protobuf", "3.25.5") do |s|
        s.required_ruby_version = "< #{current_ruby_minor}.dev"
        s.platform = "x86_64-linux"
      end
    end

    gemfile <<~G
      source "https://gem.repo4"

      gem "google-protobuf", "~> 3.0"
    G

    original_lockfile = <<~L
      GEM
        remote: https://gem.repo4/
        specs:
          google-protobuf (3.25.5)
          google-protobuf (3.25.5-x86_64-linux)

      PLATFORMS
        ruby
        x86_64-linux

      DEPENDENCIES
        google-protobuf (~> 3.0)

      BUNDLED WITH
         #{Bundler::VERSION}
    L

    lockfile original_lockfile

    simulate_platform "x86_64-linux" do
      bundle "lock --update"
    end

    expect(lockfile).to eq(original_lockfile)
  end

  private

  def setup_multiplatform_gem
    build_repo2 do
      build_gem("google-protobuf", "3.0.0.alpha.5.0.5.1")
      build_gem("google-protobuf", "3.0.0.alpha.5.0.5.1") {|s| s.platform = "x86_64-linux" }
      build_gem("google-protobuf", "3.0.0.alpha.5.0.5.1") {|s| s.platform = "x64-mingw-ucrt" }
      build_gem("google-protobuf", "3.0.0.alpha.5.0.5.1") {|s| s.platform = "universal-darwin" }

      build_gem("google-protobuf", "3.0.0.alpha.5.0.5") {|s| s.platform = "x86_64-linux" }
      build_gem("google-protobuf", "3.0.0.alpha.5.0.5") {|s| s.platform = "x64-mingw-ucrt" }
      build_gem("google-protobuf", "3.0.0.alpha.5.0.5")

      build_gem("google-protobuf", "3.0.0.alpha.5.0.4") {|s| s.platform = "universal-darwin" }

      build_gem("google-protobuf", "3.0.0.alpha.4.0")
      build_gem("google-protobuf", "3.0.0.alpha.3.1.pre")
    end
  end

  def setup_multiplatform_gem_with_different_dependencies_per_platform
    build_repo2 do
      build_gem("facter", "2.4.6")
      build_gem("facter", "2.4.6") do |s|
        s.platform = "universal-darwin"
        s.add_dependency "CFPropertyList"
      end
      build_gem("CFPropertyList")
    end
  end

  def setup_multiplatform_gem_with_source_gem
    build_repo2 do
      build_gem("my-precompiled-gem", "3.0.0")
      build_gem("my-precompiled-gem", "3.0.0") do |s|
        s.platform = Bundler.local_platform

        # purposely unresolvable
        s.required_ruby_version = ">= 1000.0.0"
      end
    end
  end
end
