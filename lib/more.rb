# Less::More provides methods for parsing LESS files in a rails application to CSS target files.
# 
# When Less::More.parse is called, all files in Less::More.source_path will be parsed using LESS
# and saved as CSS files in Less::More.destination_path. If Less::More.compression is set to true,
# extra line breaks will be removed to compress the CSS files.
#
# By default, Less::More.parse will be called for each request in `development` environment and on
# application initialization in `production` environment.

begin
  require 'less'
rescue LoadError => e
  e.message << " (You may need to install the less gem)"
  raise e
end

class Less::More
  DEFAULTS = {
    "production" => {
      :compression        => true,
      :header             => false,
      :destination_path   => "stylesheets",
      :concat             => false
    },
    "development" => {
      :compression        => false,
      :header             => true,
      :destination_path   => "stylesheets",
      :concat             => false
    }
  }
  
  HEADER = %{/*\n\n\n\n\n\tThis file was auto generated by Less (http://lesscss.org). To change the contents of this file, edit %s instead.\n\n\n\n\n*/}
  
  class << self
    attr_writer :compression, :header, :page_cache, :concat, :destination_path
    
    # Returns true if compression is enabled. By default, compression is enabled in the production environment
    # and disabled in the development and test environments. This value can be changed using:
    #
    #   Less::More.compression = true
    #
    # You can put this line into config/environments/development.rb to enable compression for the development environments
    def compression?
      get_cvar(:compression)
    end

    # Check wether or not we should page cache the generated CSS
    def page_cache?
      (not heroku?) && page_cache_enabled_in_environment_configuration?
    end
    
    # For easy mocking.
    def page_cache_enabled_in_environment_configuration?
      Rails.configuration.action_controller.perform_caching
    end
    
    # Tells the plugin to prepend HEADER to all generated CSS, informing users
    # opening raw .css files that the file is auto-generated and that the
    # .less file should be edited instead.
    #
    #    Less::More.header = false
    def header?
      get_cvar(:header)
    end
    
    # The path, or route, where you want your .css files to live.
    def destination_path
      get_cvar(:destination_path)
    end
    
    # TRP: If defined the name of the file that all generated .css files should be concated into.
    def concat
      get_cvar(:concat)
    end
    
    # Gets user set values or DEFAULTS. User set values gets precedence.
    def get_cvar(cvar)
      instance_variable_get("@#{cvar}") || (DEFAULTS[Rails.env] || DEFAULTS["production"])[cvar]
    end
    
    # Returns true if the app is running on Heroku. When +heroku?+ is true,
    # +page_cache?+ will always be false.
    def heroku?
      !!ENV["HEROKU_ENV"]
    end
    
    # Returns the LESS source path, see `source_path=`
    def source_path
      @source_path || Rails.root.join("app", "stylesheets")
    end
    
    # Sets the source path for LESS files. This directory will be scanned recursively for all *.less files. Files prefixed
    # with an underscore is considered to be partials and are not parsed directly. These files can be included using `@import`
    # statements. *Example partial filename: _form.less*
    #
    # Default value is app/stylesheets
    #
    # Examples:
    #   Less::More.source_path = "/path/to/less/files"
    #   Less::More.source_path = Pathname.new("/other/path")
    def source_path=(path)
      @source_path = Pathname.new(path.to_s)
    end
    
    # Checks if a .less or .lss file exists in Less::More.source_path matching
    # the given parameters.
    #
    #   Less::More.exists?(["screen"])
    #   Less::More.exists?(["subdirectories", "here", "homepage"])
    def exists?(path_as_array)
      return false if path_as_array[-1].starts_with?("_")
      
      pathname = pathname_from_array(path_as_array)
      pathname && pathname.exist?
    end
    
    # Generates the .css from a .less or .lss file in Less::More.source_path matching
    # the given parameters.
    #
    #   Less::More.generate(["screen"])
    #   Less::More.generate(["subdirectories", "here", "homepage"])
    #
    # Returns the CSS as a string.
    def generate(path_as_array)
      source = pathname_from_array(path_as_array)
      
      if source.extname == ".css"
        css = File.read(source)
      else
        engine = File.open(source) {|f| Less::Engine.new(f) }
        css = engine.to_css
        css.delete!("\n") if self.compression?
        css = (HEADER % [source.to_s]) << css if self.header?
      end

      css
    end
    
    # Generates all the .css files.
    def parse
      sum = []
      Less::More.all_less_files.each do |path|
        # Get path
        relative_path = path.relative_path_from(Less::More.source_path)
        path_as_array = relative_path.to_s.split(File::SEPARATOR)
        path_as_array[-1] = File.basename(path_as_array[-1], File.extname(path_as_array[-1]))

        # Generate CSS
        css = Less::More.generate(path_as_array)

        # Store CSS
        write_css(path_as_array, css)
        
        # TRP: Add up CSS (if we are concatenating)
        sum << css if concat
      end
      
      # TRP: Write the sum of all generated css files to configured concat file
      write_css(concat, sum.join) if concat
    end
    
    # TRP: Write css to destination_path with a relative path
    def write_css(path, css)
      path_as_array = [*path]
      path_as_array[-1] = path_as_array[-1] + ".css"
      destination = Pathname.new(File.join(Rails.public_path, Less::More.destination_path)).join(*path_as_array)
      destination.dirname.mkpath

      File.open(destination, "w") { |f| f.puts css }
    end
    
    # Removes all generated css files.
    def clean
      all_less_files.each do |path|
        relative_path = path.relative_path_from(Less::More.source_path)
        css_path = relative_path.to_s.sub(/(le?|c)ss$/, "css")
        css_file = File.join(Rails.root, "public", Less::More.destination_path, css_path)
        File.delete(css_file) if File.file?(css_file)
      end
    end
    
    # Array of Pathname instances for all the less source files.
    def all_less_files
      Dir[Less::More.source_path.join("**", "*.{css,less,lss}")].map! {|f| Pathname.new(f) }
    end
    
    # Converts ["foo", "bar"] into a `Pathname` based on Less::More.source_path.
    def pathname_from_array(array)
      path_spec = array.dup
      path_spec[-1] = path_spec[-1] + ".{css,less,lss}"
      Pathname.glob(File.join(self.source_path.to_s, *path_spec))[0]
    end
  end
end
