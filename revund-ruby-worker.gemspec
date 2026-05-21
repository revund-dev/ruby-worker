# frozen_string_literal: true

require_relative 'lib/ruby_worker/version'

Gem::Specification.new do |spec|
  spec.name        = 'revund-ruby-worker'
  spec.version     = RubyWorker::VERSION
  spec.authors     = ['Revund']
  spec.email       = ['hello@revund.dev']

  spec.summary     = 'Revund Ruby AST sidecar'
  spec.description = <<~DESC
    The Ruby AST sidecar for Revund. A gRPC server that implements the
    universal revund.worker.v1.Worker contract using the whitequark/parser
    gem. Installed alongside the `revund` CLI, which discovers
    revund-ruby-worker on PATH and spawns it on demand.
  DESC
  spec.homepage    = 'https://revund.dev'
  spec.license     = 'Apache-2.0'

  spec.required_ruby_version = '>= 3.0'

  spec.metadata = {
    'homepage_uri'      => spec.homepage,
    'source_code_uri'   => 'https://github.com/revund-dev/ruby-worker',
    'bug_tracker_uri'   => 'https://github.com/revund-dev/ruby-worker/issues',
    'documentation_uri' => 'https://revund.dev/docs/workers',
  }

  # Files that ship in the gem:
  #   bin/revund-ruby-worker     — executable
  #   lib/                       — Ruby source
  #   proto/worker/v1/worker.proto — vendored contract (populated by rake vendor_proto)
  #   README.md                  — at the gem root
  spec.files = Dir.glob([
    'bin/revund-ruby-worker',
    'lib/**/*.rb',
    'proto/worker/v1/worker.proto',
    'README.md',
    'LICENSE',
  ])

  spec.executables   = ['revund-ruby-worker']
  spec.require_paths = ['lib']

  # Runtime deps
  spec.add_dependency 'google-protobuf', '~> 3.25'
  spec.add_dependency 'grpc', '~> 1.62'
  spec.add_dependency 'parser', '~> 3.3'
  spec.add_dependency 'unparser', '~> 0.6'

  # Development deps live in the Gemfile, not here. The Gemfile is for
  # contributors; the gemspec is what's published to RubyGems.
end
