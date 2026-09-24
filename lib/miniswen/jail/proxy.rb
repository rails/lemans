# frozen_string_literal: true

require "fileutils"
require "socket"

module Miniswen
  class Jail < Local
    # An HTTP CONNECT proxy that lets jailed commands reach the allowed hosts only.
    class Proxy
      def self.forward(port, socket)
        server = TCPServer.new("127.0.0.1", port)
        exit!(0) if fork
        serve(server) { pump(it, UNIXSocket.new(socket)) }
      end

      def self.serve(server)
        Thread.report_on_exception = false
        loop { Thread.new(server.accept) { yield it } }
      end

      def self.pump(client, upstream)
        Thread.new do
          IO.copy_stream(client, upstream)
          upstream.close_write
        end
        IO.copy_stream(upstream, client)
      ensure
        client.close
        upstream.close
      end

      def initialize(hosts:, socket:)
        @hosts = hosts
        @socket = socket
      end

      def start
        FileUtils.rm_f(@socket)
        server = UNIXServer.new(@socket)
        @pid = fork { self.class.serve(server) { handle(it) } }
        self
      end

      def stop
        Process.kill(:KILL, @pid)
        Process.wait(@pid)
      end

      def handle(client)
        _, target = client.gets("\r\n\r\n").split(" ", 3)
        host, port = target.split(":", 2)
        return client.write("HTTP/1.1 403 Forbidden\r\n\r\n") unless @hosts.include?(host)

        upstream = Socket.tcp(host, port.to_i, connect_timeout: 10)
        client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
        self.class.pump(client, upstream)
      ensure
        client.close
      end
    end
  end
end
