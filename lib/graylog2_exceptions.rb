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

      if err.backtrace && err.backtrace.size > 0
        opts[:full_message] = "Backtrace:\n" + err.backtrace.join("\n")
        opts[:file] = err.backtrace[0].split(":")[0]
        opts[:line] = err.backtrace[0].split(":")[1]
      end

      if env and env.size > 0
        opts[:full_message] ||= ""
        opts[:full_message] << "\n\nEnvironment:\n"

        env.each do |k, v|
          begin
            opts[:full_message] << "#{k}: #{v.inspect}\n"
          rescue
          end
        end
      end
      
      notifier.notify!(opts.merge(@extra_args))
    rescue Exception => i_err
      puts "Graylog2 Exception logger. Could not send message: " + i_err.message
    end
  end

end
