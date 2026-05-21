# frozen_string_literal: true

require 'fileutils'

# Vendor the workspace's worker.proto into the gem so that publishing
# RubyGems doesn't reach outside the gem directory. Run before
# `gem build` (or `rake build` if you wire that up).
task :vendor_proto do
  src = File.expand_path('../../proto/worker/v1/worker.proto', __dir__)
  dst_dir = File.expand_path('proto/worker/v1', __dir__)
  FileUtils.mkdir_p(dst_dir)
  FileUtils.cp(src, File.join(dst_dir, 'worker.proto'))
  puts "Vendored worker.proto from #{src}"
end

task default: :vendor_proto
