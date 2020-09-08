require_relative 'lib/wordmap/version'

Gem::Specification.new do |spec|
  spec.name    = 'wordmap'
  spec.version = Wordmap::VERSION
  spec.authors = ['Maxim Chernyak']
  spec.email   = ['madfancier@gmail.com']

  spec.summary     = 'Look up data from disk without using your RAM.'
  spec.description = 'Wordmap is a simple way to lookup data directly from disk, bypassing RAM completely. It uses sysseek and sysread (no buffering), and takes advantage of SSD\'s constant seek time. The data is stored in equal size "cells" making it easy to calculate where things are located based on vectors.'
  spec.homepage    = 'https://github.com/scottscheapflights/wordmap'
  spec.license     = 'Apache-2.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = 'https://github.com/scottscheapflights/wordmap/blob/master/CHANGELOG.md'

  spec.required_ruby_version = Gem::Requirement.new('>= 2.4.0')
  spec.files = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^spec/}) }
  end
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 2.1'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.9'
  spec.add_development_dependency 'pry', '~> 0.13'
end
