# frozen_string_literal: true

require 'grpc'
require_relative 'service'

module RubyWorker
  # Server is the gRPC entry. Implements the universal
  # `revund.worker.v1.Worker` contract — same shape as ts-worker
  # and php-worker. Bind, advertise readiness on stdout, register
  # the service, serve.
  class Server
    VERSION = '0.1.0'

    def initialize(port)
      @port = port
    end

    def run
      server = GRPC::RpcServer.new
      server.add_http2_port("0.0.0.0:#{@port}", :this_port_is_insecure)
      server.handle(RubyWorker::Service.new)

      # Liveness ping for parent processes that spawn this worker
      # as a sidecar.
      $stdout.puts("ready: 0.0.0.0:#{@port}")
      $stdout.flush

      # Graceful shutdown on SIGTERM / SIGINT.
      %w[TERM INT].each do |sig|
        trap(sig) { server.stop }
      end

      server.run_till_terminated
    end
  end
end
