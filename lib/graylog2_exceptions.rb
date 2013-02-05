require 'rubygems'
require 'gelf'
require 'socket'

class Graylog2Exceptions
  attr_reader :args

  def initialize(app, args = {})
    standard_args = {
      :hostname => "localhost",
      :port => 12201,
      :local_app_name => Socket::gethostname,
      :facility => 'graylog2_exceptions',
      :max_chunk_size => 'LAN',
      :level => 3,
      :host => nil,
      :short_message => nil,
      :full_message => nil,
      :file => nil,
      :line => nil
    }

    @args = standard_args.merge(args).reject {|k, v| v.nil? }
    @extra_args = @args.reject {|k, v| standard_args.has_key?(k) }
    @app = app
  end

  def call(env)
    # Make thread safe
    dup._call(env)
  end

  def _call(env)
    begin
      # Call the app we are monitoring
      response = @app.call(env)
    rescue => err
      # An exception has been raised. Send to Graylog2!
      send_to_graylog2(err, env)

      # Raise the exception again to pass back to app.
      raise
    end

    if env['rack.exception']
      send_to_graylog2(env['rack.exception'], env)
    end

    response
  end

  # Use a naive way to identify GEM_HOME_ROOT, in some setups, working with plain ENV['GEM_HOME']
  def get_gem_home_root(arr)
    gem_string = "/gems/"
    ret = nil
    arr.each do |line|
      if line.include? gem_string
        ret = line.split(gem_string)[0] + gem_string
        break
      end
    end
    ret
  end

  def clean_stack(backtrace)
  gem_root_str = get_gem_home_root backtrace
  arr = backtrace
    if defined? gem_root_str
      arr = backtrace.each do |line|
          line.gsub! gem_root_str, "[GEM_HOME]/"
      end
    end
    arr.join("\n")
  end

  def send_to_graylog2(err, env=nil)
    begin
      notifier = GELF::Notifier.new(@args[:hostname], @args[:port], @args[:max_chunk_size])
      notifier.collect_file_and_line = false
      
      opts = {
          :short_message => err.message,
          :facility => @args[:facility],
          :level => @args[:level],
          :host => @args[:local_app_name]
      }

      if env and env.size > 0
        opts[:full_message] ||= ""
        opts[:full_message] << ">> MAIN_ENV <<:\n"
        env.each do |k, v|
          continue unless ["HTTP_ORIGIN", "HTTP_REFERER", "CONTENT_TYPE", "HTTP_USER_AGENT", "REMOTE_ADDR", "REQUEST_URI"].includes? k
          begin
            opts[:full_message] << " * #{k}: #{v}\n"
          rescue
          end
        end        
      end

      if err.backtrace && err.backtrace.size > 0
        opts[:full_message] << ">> BACKTRACE <<\n"
        opts[:full_message] << clean_stack(err.backtrace)
        opts[:full_message] << "\n"

        opts[:file] = err.backtrace[0].split(":")[0]
        opts[:line] = err.backtrace[0].split(":")[1]
      end

      if env and env.size > 0
        opts[:full_message] << ">> ENVIRONMENT <<:\n"

        env.each do |k, v|
          begin
            opts[:full_message] << " * #{k}: #{v}\n"
          rescue
          end
        end

        opts[:full_message] << "\n"
        opts[:full_message] << " * Process: #{$$}\n"
        opts[:full_message] << " * Server: #{`hostname`.chomp}\n"
      end
      
      notifier.notify!(opts.merge(@extra_args))
    rescue Exception => i_err
      puts "Graylog2 Exception logger. Could not send message: " + i_err.message
    end
  end

end
