module Gem

  ##
  # The installer class processes RubyGem .gem files and installs the
  # files contained in the .gem into the Gem.path.
  #
  class Installer
  
    ##
    # Constructs a Installer instance
    #
    # gem:: [String] The file name of the gem
    #
    def initialize(gem)
      @gem = gem
    end
    
    ##
    # Installs the gem in the Gem.path.  This will fail (unless
    # force=true) if a Gem has a requirement on another Gem that is
    # not installed.  The installation will install in the following
    # structure:
    #
    #  Gem.path/
    #      specifications/<gem-version>.gemspec #=> the extracted YAML gemspec
    #      gems/<gem-version>/... #=> the extracted Gem files
    #      cache/<gem-version>.gem #=> a cached copy of the installed Gem
    #
    # force:: [default = false] if false will fail if a required Gem is not installed
    # install_dir:: [default = Gem.dir] directory that Gem is to be installed in
    # install_stub:: [default = true] causes the installation of a library stub in the +site_ruby+ directory
    #
    # return:: [Gem::Specification] The specification for the newly installed Gem.
    #
    def install(force=false, install_dir=Gem.dir, install_stub=true)
      require 'fileutils'
      format = Gem::Format.from_file_by_path(@gem)
      unless force
         format.spec.dependencies.each do |dep_gem|
           # XXX: Does this take account of *versions*?
           require_gem(dep_gem)
         end
       end

       # Build spec dir.
       directory = File.join(install_dir, "gems", format.spec.full_name)
       FileUtils.mkdir_p directory
       extract_files(directory, format)
       generate_bin_scripts(format.spec)
       generate_library_stubs(format.spec) if install_stub
       build_extensions(directory, format.spec)
       
       # Build spec/cache/doc dir.
       unless File.exist? File.join(install_dir, "specifications")
         FileUtils.mkdir_p File.join(install_dir, "specifications")
       end
       unless File.exist? File.join(install_dir, "cache")
         FileUtils.mkdir_p File.join(install_dir, "cache")
       end
       unless File.exist? File.join(install_dir, "doc")
         FileUtils.mkdir_p File.join(install_dir, "doc")
       end
       
       # Write the spec and cache files.
       write_spec(format.spec, File.join(install_dir, "specifications"))
       unless(File.exist?(File.join(File.join(install_dir, "cache"), @gem.split(/\//).pop))) 
         FileUtils.cp(@gem, File.join(install_dir, "cache"))
       end

       puts "Successfully installed #{format.spec.name} version #{format.spec.version}"
       format.spec.loaded_from = File.join(install_dir, 'specifications', format.spec.full_name+".gemspec")
       return format.spec
    end
    
    ##
    # Writes the .gemspec specification (in Ruby) to the supplied spec_path.
    #
    # spec:: [Gem::Specification] The Gem specification to output
    # spec_path:: [String] The location (path) to write the gemspec to
    #
    def write_spec(spec, spec_path)
      File.open(File.join(spec_path, spec.full_name+".gemspec"), "w") do |file|
        file.puts spec.to_ruby
      end
    end

    ##
    # Creates the scripts to run the applications in the gem.
    #
    def generate_bin_scripts(spec)
      if spec.executables
        require 'rbconfig'
        bindir = Config::CONFIG['bindir']
        is_windows_platform = Config::CONFIG["arch"] =~ /dos|win32/i
        spec.executables.each do |filename|
          File.open(File.join(bindir, File.basename(filename)), "w", 0755) do |file|
            file.print(app_script_text(spec.name, spec.version.version, filename))
          end
        end
      #if is_windows_platform
        #File.open(target+".cmd", "w") do |file|
          #file.puts "@ruby #{target} %1 %2 %3 %4 %5 %6 %7 %8 %9"
        #end
      #end
      end
    end

    ##
    # Returns the text for an application file.
    #
    def app_script_text(name, version, filename)
      text = <<-TEXT
#!#{File.join(Config::CONFIG['bindir'], Config::CONFIG['ruby_install_name'])}

#
# This file was generated by RubyGems.
#
# The application '#{name}' is installed as part of a gem, and
# this file is here to facilitate running it. 
#

require 'rubygems'
require_gem '#{name}', "#{version}"
load '#{filename}'  
TEXT
      text
    end

    ##
    # Creates a file in the site_ruby directory that acts as a stub for the gem.  Thus, if
    # 'package' is installed as a gem, the user can just type <tt>require 'package'</tt> and
    # the gem (latest version) will be loaded.  This is like a backwards compatibility so that
    # gems and non-gems can interact.
    #
    # XXX: What if the user doesn't have permission to write to the site_ruby directory? 
    #      Answer for now: emit warning.  This is bad practice (we're in library code here,
    #      and should not write directly to stderr.  It's something to reconsider in the
    #      future. 
    #
    def generate_library_stubs(spec)
      if spec.autorequire
        require 'rbconfig'
        sitelibdir = Config::CONFIG['sitelibdir']
        if FileTest.writable?(sitelibdir)
          target_file = File.join(sitelibdir, "#{spec.autorequire}.rb")
          if FileTest.exist?(target_file) 
            STDERR.puts "(WARN) Library file '#{target_file}'"
            STDERR.puts "       already exists; not overwriting.  If you want to force a"
            STDERR.puts "       library stub, delete the file and reinstall."
          else
            # Create #{autorequire}.rb in #{target_dir}.
            File.open(target_file, "w", 0644) do |file|
              file.write(library_stub_text(spec.name))
            end
          end
        else
          rver = Config::CONFIG['ruby_version']
          STDERR.puts "(WARN) Can't install library stub for gem '#{spec.name}'"
          STDERR.puts "       (Don't have write permissions on 'site_ruby/#{rver}' directory.)"
        end
      end
    end
    
    ##
    # Returns the text for the library stub.
    #
    def library_stub_text(name)
      text = <<-TEXT
#
# This file was generated by RubyGems.
#
# The library '#{name}' is installed as part of a gem, and
# this file is here so you can 'require' it easily (i.e.
# without having to know it's a gem).
#

require 'rubygems'
require_gem '#{name}'
TEXT
      text
    end
    
    def build_extensions(directory, spec)
      return unless spec.extensions.size > 0
      start_dir = Dir.pwd
      dest_path = File.join(directory, spec.require_paths[0])
      spec.extensions.each do |extension|
        Dir.chdir File.join(directory, File.dirname(extension))
        results = ["ruby #{File.basename(extension)} #{ARGV.join(" ")}"]
        results << `ruby #{File.basename(extension)} #{ARGV.join(" ")}`
        if File.exist?('Makefile')
          mf = File.read('Makefile')
          mf = mf.gsub(/^RUBYARCHDIR\s*=\s*\$.*/, "RUBYARCHDIR = #{dest_path}")
          mf = mf.gsub(/^RUBYLIBDIR\s*=\s*\$.*/, "RUBYLIBDIR = #{dest_path}")
          File.open('Makefile', 'wb') {|f| f.print mf}
          make_program = ENV['make']
          unless make_program
            make_program = (/mswin/ =~ RUBY_PLATFORM) ? 'nmake' : 'make'
          end
          results << "#{make_program}"
          results << `#{make_program}`
          results << "#{make_program} install"
          results << `#{make_program} install`
          puts results.join("\n")
        else
          puts "ERROR: Failed to build gem native extension.\n  See #{File.join(Dir.pwd, 'gem_make.out')}"
        end
        File.open('gem_make.out', 'wb') {|f| f.puts results.join("\n")}
      end
      Dir.chdir start_dir
    end
    
    ##
    # Reads the YAML file index and then extracts each file
    # into the supplied directory, building directories for the
    # extracted files as needed.
    #
    # directory:: [String] The root directory to extract files into
    # file:: [IO] The IO that contains the file data
    #
    def extract_files(directory, format)
      require 'fileutils'
      wd = Dir.getwd
      Dir.chdir directory
      begin
        format.file_entries.each do |entry, file_data|
          path = entry['path']
          mode = entry['mode']
          FileUtils.mkdir_p File.dirname(path)
          File.open(path, "wb") do |out|
            out.write file_data
          end
        end
      ensure
        Dir.chdir wd
      end
    end
  end

  
  ##
  # The Uninstaller class uninstalls a Gem
  #
  class Uninstaller
  
    ##
    # Constructs an Uninstaller instance
    # 
    # gem:: [String] The Gem name to uninstall
    #
    def initialize(gem, version="> 0")
      @gem = gem
      @version = version
    end
    
    ##
    # Performs the uninstall of the Gem.  This removes the spec, the Gem directory, and the
    # cached .gem file,
    #
    # Application and library stubs are removed according to what is still installed.
    #
    # XXX: Application stubs refer to specific gem versions, which means things may get
    # inconsistent after an uninstall (i.e. referring to a version that no longer exists).
    #
    def uninstall
      require 'fileutils'
      cache = Cache.from_installed_gems
      list = cache.search(@gem, @version)
      if list.size == 0 
        puts "Unknown RubyGem: #{@gem} (#{@version})"
      elsif list.size > 1
        puts "Select RubyGem to uninstall:"
        list.each_with_index do |gem, index|
          puts " #{index+1}. #{gem.full_name}"
        end
        puts " #{list.size+1}. All versions"
        print "> "
        response = STDIN.gets.strip.to_i - 1
        if response == list.size
          # list.each { |gem| remove(gem) }
          remove_all(list) 
        elsif response >= 0 && response < list.size
          remove(list[response], list)
        else
          puts "Error: must enter a number [1-#{list.size+1}]"
        end
      else
        remove(list[0], list)
      end
    end
    
    #
    # spec:: the spec of the gem to be uninstalled
    # list:: the list of all such gems
    #
    # Warning: this method modifies the +list+ parameter.  Once it has uninstalled a gem, it is
    # removed from that list.
    #
    def remove(spec, list)
      if(has_dependents?(spec)) then
        raise "Uninstallation aborted due to dependent gem(s)"
      end
      FileUtils.rm_rf spec.full_gem_path
      FileUtils.rm_rf File.join(spec.installation_path, 'specifications', "#{spec.full_name}.gemspec")
      FileUtils.rm_rf File.join(spec.installation_path, 'cache', "#{spec.full_name}.gem")
      DocManager.new(spec).uninstall_doc
      _remove_stub_files(spec, list - [spec])
      puts "Successfully uninstalled #{spec.name} version #{spec.version}"
      list.delete(spec)
    end

    def has_dependents?(spec)
      spec.dependent_gems.each do |gem,dep,satlist|
        puts "WARNING: #{gem.name}-#{gem.version} depends on [#{dep.name} (#{dep.version_requirement})], which is satisifed by this gem.  This dependency is satisfied by:"
        satlist.each do |sat|
          puts "\t#{sat.name}-#{sat.version}"
        end
        print "Uninstall anyway? [Y/n]"
        answer = STDIN.gets
        if(answer !~ /^y/i) then
          return true
        end
      end
      false
    end

    private

    ##
    # Remove application and library stub files.  These are detected by the line
    #   # This file was generated by RubyGems. 
    #
    # spec:: the spec of the gem that is being uninstalled
    # other_specs:: any other installed specs for this gem (i.e. different versions)
    #
    # Both parameters are necessary to ensure that the correct files are uninstalled.  It is
    # assumed that +other_specs+ contains only *installed* gems, except the one that's about to
    # be uninstalled.
    #
    def _remove_stub_files(spec, other_specs)
      _remove_app_stubs(spec, other_specs)
      _remove_lib_stub(spec, other_specs)
    end

    def _remove_app_stubs(spec, other_specs)
      # App stubs are tricky, because each version of an app gem could install different
      # applications.  We need to make sure that what we delete isn't needed by any remaining
      # versions of the gem.
      #
      # There's extra trickiness, too, because app stubs 'require_gem' a specific version of
      # the gem.  If we uninstall the latest gem, we should ensure that there is a sensible app
      # stub(s) installed after the removal of the current one.
      #
      # Perhaps the best way to approach this is:
      #  * remove all application stubs for this gemspec
      #  * regenerate the app stubs for the latest remaining version
      #    (you always want to have the latest version of an app, don't you?)
      #
      # The Installer class doesn't really support this approach very well at the moment.
    end

    def _remove_lib_stub(spec, other_specs)
      # Library stubs are a bit easier than application stubs.  They do not refer to a specific
      # version; they just load the latest version of the library available as a gem.  The only
      # corner case is that different versions of the same gem may have different autorequire
      # settings, which means they will have different library stubs.
      #
      # I suppose our policy should be: when you uninstall a library, make sure all the
      # remaining versions of that gem are still supported by stubs.  Of course, the user may
      # have expressed a preference in the past not to have library stubs installed.
      #
      # Mixing the segregated world of gem installations with the global namespace of the
      # site_ruby directory certainly brings some tough issues.
    end
  end  # class Uninstaller
end
