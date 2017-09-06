require 'rubygems'
require 'gelf'
require 'socket'
require 'logger'
require 'concurrent'
require_relative './local_logger'

class Graylog2Exceptions
  attr_reader :args
  attr_writer :env_ref

  FULL_MESSAGE_FIELDS = %w(HTTP_ORIGIN HTTP_REFERER CONTENT_TYPE HTTP_USER_AGENT REMOTE_ADDR REQUEST_URI FIVERR_MESSSAGE).freeze
  BACKTRACE_START = 4 # In case of no exception object, use the caller array starting from this element(1 based index)
  NO_EXCEPTION = 'NO_EXCEPTION_GIVEN!'.freeze
  FIVERR_MESSAGE = 'FIVERR_MESSSAGE'.freeze

  def initialize(app, args = {})
    standard_args = {
      hostname: "localhost",
      port: 12201,
      local_app_name: Socket::gethostname,
      facility: 'graylog2_exceptions',
      max_chunk_size: 'LAN',
      level: Logger::ERROR,
      host: nil,
      short_message: nil,
      full_message: nil,
      file: nil,
      line: nil
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

  def send_to_graylog2(err, env = nil, log_level = nil)
    begin

      opts = {
          short_message: err.message,
          full_message: "",
          facility: @args[:facility],
          level: log_level || @args[:level],
          host: @args[:local_app_name]
      }

      if env && env.size > 0
        opts[:full_message] << "   >>>> MAIN_ENV <<<<\n"
        env.each do |k, v|
          next unless FULL_MESSAGE_FIELDS.include? k
          begin
            opts[:full_message] << " * #{k}: #{v}\n"
          rescue
          end
        end
      end

      if err && err.backtrace && err.backtrace.size > 0
        opts[:full_message] << "\n   >>>> BACKTRACE <<<<\n"
        opts[:full_message] << clean_stack(err.backtrace)
        opts[:full_message] << "\n"

        opts[:file] = err.backtrace[0].split(":")[0]
        opts[:line] = err.backtrace[0].split(":")[1]
      end

      if env && env.size > 0
        if env["current_user"]
          opts[:full_message] << "\n   >>>> CURRENT USER <<<<\n"
          opts[:full_message] << " * CURRENT_USER: #{env["current_user"].inspect}\n\n"
        end

        opts[:full_message] << "\n   >>>> ENVIRONMENT <<<<\n"

        env.each do |env_key, env_value|
          begin
            env_value = env_value
            opts[:full_message] << " * #{env_key}: #{env_value}\n"
          rescue
          end
        end

        opts[:full_message] << "\n"
        opts[:full_message] << " * Process: #{$$}\n"
        opts[:full_message] << " * Server: #{`hostname`.chomp}\n"
      end

      # Actual message posting is done oby dedicated thread.
      thread_pool.post do
        begin
          notifier.notify!(opts.merge(@extra_args))
        rescue StandardError => e
          LocalLogger.logger.error "Graylog2Exceptions#send_to_graylog2 Could not send message: #{e.message}, backtrace #{e.backtrace}"
        end
      end

    rescue => e
      LocalLogger.logger.error "Graylog2Exceptions#send_to_graylog2 Could not send message: #{e.message}, backtrace #{e.backtrace}"
    end
  end

  def debug(klass, message, exception = nil)
    send_with_level(klass, message, exception, Logger::DEBUG)
  end

  def info(klass, message, exception = nil)
    send_with_level(klass, message, exception, Logger::INFO)
  end

  def warning(klass, message, exception = nil)
    send_with_level(klass, message, exception, Logger::WARN)
  end
  alias_method :warn, :warning

  def error(klass, message, exception = nil)
    send_with_level(klass, message, exception, Logger::ERROR)
  end

  private

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
        next if gem_root_str.nil?
        line.gsub! gem_root_str, "[GEM_HOME]/"
      end
    end
    arr.join("\n")
  end

  def send_with_level(klass, message, exception, level)
    raise "#{klass} - #{message} - #{exception.inspect}" if @args[:raise_on_graylog]

    begin
      formatted_exception = format_exception(klass, message, exception)
      env = get_env_ref
      env[FIVERR_MESSAGE] = message

      send_to_graylog2(formatted_exception, env, level)
    rescue => e
      LocalLogger.logger.error "Graylog2Exceptions#send_with_level: #{e.inspect} and #{e.backtrace}"
    end
  end

  def format_exception(klass, message, exception)
    data, backtrace = exception_attributes(exception)
    formatted_exception = Exception.new("Class: #{klass}\nMessage: #{message}.\n#{data}")
    formatted_exception.set_backtrace(backtrace)
    formatted_exception
  end

  def exception_attributes(exception)
    case exception
      when Exception
        ["Attributes: #{exception}", exception.backtrace]
      else
        [NO_EXCEPTION, caller(BACKTRACE_START)]
    end
  end

  def get_env_ref
    @env_ref && @env_ref.respond_to?(:env) && @env_ref.env || {}
  end

  def notifier
    @gelf_notifier ||= GELF::Notifier.new(@args[:hostname], @args[:port], @args[:max_chunk_size])
    @gelf_notifier.collect_file_and_line = false
    @gelf_notifier
  end

  def thread_pool
    # Lazy thread creation.
    @pool ||= Concurrent::SingleThreadExecutor.new
  end
end
