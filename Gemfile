# Gemfile for ruby-worker — Revund's Ruby AST sidecar.
#
# Built on the whitequark/parser gem — the same library
# RuboCop, Sorbet, Brakeman, and every serious Ruby static
# analyzer ship on. Choosing parser (rather than rolling
# our own or shelling to `ruby -ryaml -e
# 'RubyVM::AbstractSyntaxTree.parse'`) buys us:
#
#   - Stable AST shape across Ruby 2.6 → 3.3
#   - Comment preservation, exact line + column tracking
#   - Error recovery on syntactically-broken files

source 'https://rubygems.org'

ruby '~> 3.0'

# AST parsing
gem 'parser', '~> 3.3'      # whitequark/parser
gem 'unparser', '~> 0.6'    # round-trip for canonical hashing

# gRPC stack
gem 'grpc', '~> 1.62'
gem 'grpc-tools', '~> 1.62', require: false  # codegen only
gem 'google-protobuf', '~> 3.25'

group :development do
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.60', require: false
end
