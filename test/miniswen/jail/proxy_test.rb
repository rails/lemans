# frozen_string_literal: true

require "test_helper"
require "miniswen/jail"

class MiniswenJailProxyTest < Minitest::Test
  def connect(hosts, request)
    client, server = UNIXSocket.pair
    client.write(request)
    client.close_write
    Miniswen::Jail::Proxy.new(hosts: hosts, socket: "/nonexistent").handle(server)
    client.read.lines.first.to_s.strip
  end

  def test_only_connect_to_a_listed_host_goes_through
    assert_equal "HTTP/1.1 403 Forbidden", connect([ "example.com" ], "CONNECT evil.example.net:443 HTTP/1.1\r\n\r\n")
    assert_equal "HTTP/1.1 403 Forbidden", connect([ "example.com" ], "CONNECT sub.example.com:443 HTTP/1.1\r\n\r\n")
    assert_equal "HTTP/1.1 403 Forbidden", connect([ "example.com" ], "GET http://example.com/ HTTP/1.1\r\n\r\n")
  end
end
