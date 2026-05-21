# frozen_string_literal: true

require 'fileutils'

# Vendor the workspace's worker.proto into the gem so that publishing
# to RubyGems doesn't reach outside the gem directory. Run before
# `gem build`.
task :vendor_proto do
  src = File.expand_path('../../proto/worker/v1/worker.proto', __dir__)
  unless File.exist?(src)
    warn "vendor_proto: #{src} not found (standalone checkout?). Skipping."
    next
  end
  dst_dir = File.expand_path('proto/worker/v1', __dir__)
  FileUtils.mkdir_p(dst_dir)
  FileUtils.cp(src, File.join(dst_dir, 'worker.proto'))
  puts "Vendored worker.proto from #{src}"
end

# Generate the gRPC Ruby stubs (worker_pb.rb +
# worker_services_pb.rb) under lib/worker/v1/ so service.rb can
# `require 'worker/v1/worker_pb'` and bind to
# ::Revund::Worker::V1::WorkerStub at boot.
#
# Output lands under lib/ so consumers of the gem auto-pick it up
# via standard require paths — no extra load-path config needed.
#
# Depends on the `grpc-tools` gem; run `bundle install` first.
task :gen_stubs => :vendor_proto do
  sh 'bundle exec grpc_tools_ruby_protoc' \
     ' --proto_path=proto' \
     ' --ruby_out=lib' \
     ' --grpc_out=lib' \
     ' proto/worker/v1/worker.proto'
  puts 'Generated lib/worker/v1/worker_pb.rb + worker_services_pb.rb'
end

task default: :gen_stubs
