require 'rubygems'
require 'gelf'
require 'socket'
require 'logger'
require 'concurrent'
require_relative './local_logger'

class Graylog2Exceptions
  attr_reader :args
  attr_writer :env_ref

  FULL_MESSAGE_FIELDS = %w(HTTP_HOST HTTP_ORIGIN HTTP_REFERER REQUEST_METHOD REQUEST_PATH CONTENT_TYPE HTTP_USER_AGENT REMOTE_ADDR REQUEST_URI FIVERR_MESSSAGE current_user page_ctx_id session_locale HTTP_X_OFFICE_IP HTTP_X_KNOWN_CRAWLER_CLASSIFICATION HTTP_X_PX_CTX).freeze
  BACKTRACE_START = 4 # In case of no exception object, use the caller array starting from this element(1 based index)
  NO_EXCEPTION = 'NO_EXCEPTION_GIVEN!'.freeze
  FIVERR_MESSAGE = 'FIVERR_MESSAGE'.freeze

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
    @backtrace_cleaner = get_backtrace_cleaner
    @app = app

  end

  def call(env)
    # Make thread safe
    dup._call(env)
  end

  def _call(env)
    begin
      response = @app.call(env)
    rescue SyntaxError => err
      send_to_graylog2(err, env)
      raise
    rescue => err
      send_to_graylog2(err, env)
      raise
    end

    if env['rack.exception']
      send_to_graylog2(env['rack.exception'], env)
    end

    response
  end

  def send_to_graylog2(err, env = nil, log_level = nil)
    full_message = build_full_message(env, err)

    log_message = {
      full_message: full_message,
      facility: @args[:facility],
      host: @args[:local_app_name],
      level: log_level || @args[:level],
    }

    if err
      log_message[:short_message] = err.message
      log_message[:file], log_message[:line] = extract_file_line(err)
    end

    graylog = log_message.merge(@extra_args)
    notify_graylog!(graylog)
  rescue => e
    LocalLogger.logger.error "Graylog2Exceptions#send_to_graylog2: Failed to send graylog: #{e.message}, backtrace #{e.backtrace}"
  end

  def notify_graylog!(graylog)
    # Actual message posting is done oby dedicated thread.
    thread_pool.post do
      begin
        notifier.notify!(graylog)
      rescue => e
        LocalLogger.logger.error "Graylog2Exceptions#send_to_graylog2: Failed to notify graylog: #{e.message}, backtrace #{e.backtrace}"
      end
    end
  end

  def extract_file_line(err)
    err.backtrace[0].split(":") rescue nil
  end

  def build_full_message(env, err)
    full_message = ''

    if env && env.size > 0
      full_message << "   >>>> MAIN_ENV <<<<\n"
      env.each do |k, v|
        next unless FULL_MESSAGE_FIELDS.include?(k)

        begin
          value = v && k == 'current_user' ? v.id : v
          full_message << " * #{k}: #{value}\n"
        rescue => e
          LocalLogger.logger.error "Graylog2Exceptions#build_full_message: Failed to parse env field '#{k}': #{e.message}"
        end
      end

      full_message << " * Process: #{$$}\n"
      full_message << " * Server: #{`hostname`.chomp}\n"
    end

    if err && err.backtrace && err.backtrace.size > 0
      full_message << "\n   >>>> BACKTRACE <<<<\n"
      full_message << clean_stack(err.backtrace)
      full_message << "\n"
    end

    full_message
  rescue => e
    LocalLogger.logger.error "Graylog2Exceptions#build_full_message: Failed to build full_message: #{e.message}"
    ''
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

  def clean(backtrace)
    gem_root_str = get_gem_home_root backtrace
    arr = backtrace
    if defined? gem_root_str
      arr = backtrace.each do |line|
        next if gem_root_str.nil?
        line.gsub! gem_root_str, "[GEM_HOME]/"
      end
    end
    arr
  end

  def clean_stack(backtrace)
    @backtrace_cleaner.clean(backtrace).join("\n")
  end

  def get_backtrace_cleaner
    if defined? ActiveSupport::BacktraceCleaner
      require_relative './backtrace_cleaner'
      Fiverr::BacktraceCleaner.new
    else
      self
    end
  end

  def send_with_level(klass, message, exception, level)
    raise "#{klass} - #{message} - #{exception.inspect}" if @args[:raise_on_graylog]

    begin
      formatted_exception = format_exception(klass, message, exception)
      env = get_env_ref
      env[FIVERR_MESSAGE] = message

      send_to_graylog2(formatted_exception, env, level)
    rescue => e
      LocalLogger.logger.error "Graylog2Exceptions#send_with_level: #{e.message}, #{e.backtrace}"
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
