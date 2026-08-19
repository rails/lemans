# frozen_string_literal: true

module Lemans
  class Config
    class NetworkPolicy # :nodoc:
      MODES = %w[none allowlist public].freeze

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
        @mode = mode
        @hosts = hosts
      end
    end
  end
end
