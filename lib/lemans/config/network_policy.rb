# frozen_string_literal: true

require "ipaddr"

module Lemans
  class Config
    class NetworkPolicy # :nodoc:
      MODES = %w[none allowlist public].freeze

      MODES.each do |name|
        define_method(:"#{name}?") { mode == name.to_s }
      end

      class << self
        def from_config(data)
          return if data.nil?

          mode = (data["mode"] || "public").to_s
          raise ConfigError, "#{mode.inspect} is not a network mode (#{MODES.join(", ")})" unless MODES.include?(mode)

          hosts = data["hosts"]
          raise ConfigError, "network.hosts is only meaningful with mode: allowlist" if mode != "allowlist" && hosts
          raise ConfigError, "network.hosts must be provided with mode: allowlist" if mode == "allowlist" && Array(hosts).empty?

          new(mode, hosts)
        end
      end

      attr_reader :mode, :hosts

      def initialize(mode = "public", hosts = nil)
        @mode = mode.to_s
        @hosts = hosts
      end

      def to_h = { "mode" => mode, "hosts" => hosts }.compact

      # Backends allowlist domains and IP ranges through separate APIs.
      def domains = partitioned_hosts.last

      def ip_targets = partitioned_hosts.first

      private

      def partitioned_hosts
        @partitioned_hosts ||= Array(hosts).partition { ip_target?(it) }
      end

      def ip_target?(entry)
        IPAddr.new(entry)
        true
      rescue IPAddr::Error
        false
      end
    end
  end
end
