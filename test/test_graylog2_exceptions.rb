require 'helper'
require 'logger'

class TestGraylog2Exceptions < Test::Unit::TestCase

  # Exceptions raised in the app should be thrown back
  # to the app after handling. Simulating this by giving
  # a nil app and expecting the caused exceptions.
  def test_should_rethrow_exception
    c = Graylog2Exceptions.new(nil, {})
    assert_raise NoMethodError do
      c.call nil
    end
  end

  def test_correct_parameters_when_custom_set
    c = Graylog2Exceptions.new(nil, {:host => "localhost", :port => 1337, :max_chunk_size => 'WAN', :local_app_name => "yomama", :level => 1})
    
    assert_equal "yomama", c.args[:local_app_name]
    assert_equal "localhost", c.args[:hostname]
    assert_equal 1337, c.args[:port]
    assert_equal 'WAN', c.args[:max_chunk_size]
    assert_equal 1, c.args[:level]
  end
  
  def test_add_custom_attributes_to_parameters
    c = Graylog2Exceptions.new(nil, {:_app => "my_awesome_app", :_rails_env => "staging"})
    
		assert_equal "my_awesome_app", c.args[:_app]
		assert_equal "staging", c.args[:_rails_env]
  end

  def test_custom_attributes_dont_override_standard
    ex = build_exception
    c = Graylog2Exceptions.new(nil, {:line => 9999})
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex).join)
    json = JSON.parse(sent)

    assert 9999 != json["line"]
  end

  def test_correct_parameters_when_not_custom_set
    c = Graylog2Exceptions.new(nil, {})
    
    assert_equal Socket.gethostname, c.args[:local_app_name]
    assert_equal "localhost", c.args[:hostname]
    assert_equal 12201, c.args[:port]
    assert_equal 'LAN', c.args[:max_chunk_size]
    assert_equal 3, c.args[:level]
  end

  def test_send_exception_to_graylog2_without_custom_parameters
    ex = build_exception
    c = Graylog2Exceptions.new(nil, {})
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex).join)
    json = JSON.parse(sent)

    assert json["short_message"].include?('undefined method `klopfer!')
    assert json["full_message"].include?('in `build_exception')
    assert_equal 'graylog2_exceptions', json["facility"]
    assert_equal 4, json["level"]
    assert_equal Socket.gethostname, json["host"]
    assert_equal ex.backtrace[0].split(":")[1], json["line"]
    assert_equal ex.backtrace[0].split(":")[0], json["file"]
  end
  
  def test_send_exception_to_graylog2_with_custom_parameters
    ex = build_exception

    c = Graylog2Exceptions.new(nil, {:local_app_name => "machinexx", :level => 4, :facility => 'myfacility'})
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex).join)
    json = JSON.parse(sent)

    assert json["short_message"].include?('undefined method `klopfer!')
    assert json["full_message"].include?('in `build_exception')
    assert_equal 'myfacility', json["facility"]
    assert_equal 3, json["level"]
    assert_equal "machinexx", json["host"]
    assert_equal ex.backtrace[0].split(":")[1], json["line"]
    assert_equal ex.backtrace[0].split(":")[0], json["file"]
  end

  def test_send_exception_to_graylog2_with_custom_attributes
    ex = build_exception

    c = Graylog2Exceptions.new(nil, {
			:local_app_name => "machinexx", :level => 4, :facility => 'myfacility',
			:_app => "my_awesome_app", :_rails_env => "staging"
		})
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex).join)
    json = JSON.parse(sent)

    assert json["short_message"].include?('undefined method `klopfer!')
    assert json["full_message"].include?('in `build_exception')
    assert_equal 'myfacility', json["facility"]
    assert_equal 3, json["level"]
    assert_equal "machinexx", json["host"]
    assert_equal ex.backtrace[0].split(":")[1], json["line"]
    assert_equal ex.backtrace[0].split(":")[0], json["file"]
    assert_equal 'my_awesome_app', json["_app"]
    assert_equal 'staging', json["_rails_env"]
  end

  def test_send_backtraceless_exception_to_graylog2
    ex = Exception.new("bad")
    c = Graylog2Exceptions.new(nil, {})
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex).join)
    json = JSON.parse(sent)

    assert json["short_message"].include?('bad')
    assert json["full_message"].nil?
  end

  def test_send_rack_environment_to_graylog2
    ex = build_exception
    c = Graylog2Exceptions.new(nil, {})

    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex).join)
    json = JSON.parse(sent)
    assert json.keys.none? {|k| k =~/^_env_/ }

    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex, {}).join)
    json = JSON.parse(sent)
    assert json.keys.none? {|k| k =~/^_env_/ }

    bad = Object.new
    def bad.inspect; raise "bad"; end
    data = {
        "nil" => nil,
        "str" => "bar",
        "int" => 123,
        "arr" => ["a", 2],
        "hash" => {"a" => 1},
        "obj" => Object.new,
        "bad" => bad
    }
    
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex, data).join)
    json = JSON.parse(sent)

    assert json["full_message"].include?('123')
    assert json["full_message"].include?('bad')

    assert ! json.has_key?("_env_bad")
  end

  def test_send_pid_to_graylog
    ex = build_exception

    c = Graylog2Exceptions.new(nil)
    env = { 'test' => 1 }
    sent = Zlib::Inflate.inflate(c.send_to_graylog2(ex, env).join)
    json = JSON.parse(sent)

    assert json["full_message"].include?("Process: #{$$}")
    assert json["full_message"].include?("Server: #{`hostname`.chomp}")
  end

  def test_invalid_port_detection
    ex = build_exception

    c = Graylog2Exceptions.new(nil, {:port => 0})

    # send_to_graylog2 returns nil when nothing was sent
    # the test is fine when the message is just not sent
    # and there are no exceptions. the method informs
    # the user via puts
    assert_nil c.send_to_graylog2(ex)
  end

  private

  # Returns a self-caused exception we can send.
  def build_exception
    begin
      klopfer!
    rescue => e
      return e
    end
  end

end
