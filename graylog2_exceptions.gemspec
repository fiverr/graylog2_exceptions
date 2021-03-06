# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
Gem::Specification.new do |spec|
spec.name          = 'friendlyfashion-graylog2_exceptions'
spec.version       = '1.8.14'
spec.authors       = ['Fiverr']
spec.email         = ['dev@fiverr.com']
spec.summary       = 'Graylog2 exception notifier'
spec.description   = 'A Rack middleware that sends every Exception as GELF message to your Graylog2 server'
spec.homepage      = 'https://github.com/fiverr/friendlyfashion-graylog2_exceptions'
spec.files         = `git ls-files -z`.split(" ").reject { |f| f.match(%r{^(test|spec|features)/}) }
spec.bindir        = 'bin'
spec.executables   = []
spec.require_paths = ["lib"]
spec.required_ruby_version = [">= 0"]
spec.add_runtime_dependency 'gelf', [">= 0"]
spec.add_runtime_dependency 'concurrent-ruby', ["~> 1.0.0"]
spec.add_runtime_dependency 'concurrent-ruby-ext', ["~> 1.0.0"]
end