# frozen_string_literal: true

require "ipaddr"

module Lemans
  # What a phase is allowed to reach. Every phase names its policy explicitly:
  #   network: { mode: allowlist, hosts: [openrouter.ai, "*.example.com", 10.0.0.0/8] }
  class NetworkPolicy
    MODES = %i[none allowlist public].freeze

    attr_reader :mode, :hosts, :domains, :ip_targets

    def self.from_config(config, field:)
      raise ConfigError, "#{field}: network policy is required" if config.nil?

      mode = config["mode"] or raise ConfigError, "#{field}.mode is required (#{MODES.join(", ")})"
      new(mode: mode.to_s.to_sym, hosts: config["hosts"] || [], field: field)
    end

    def self.none = new(mode: :none)

    def initialize(mode:, hosts: [], field: "network")
      unless MODES.include?(mode)
        raise ConfigError,
              "#{field}.mode: #{mode.inspect} is not one of #{MODES.join(", ")}"
      end

      raise ConfigError, "#{field}.hosts must be a list" unless hosts.is_a?(Array)
      if mode != :allowlist && !hosts.empty?
        raise ConfigError,
              "#{field}.hosts is only meaningful with mode: allowlist"
      end

      raise ConfigError, "#{field}.hosts cannot be empty with mode: allowlist" if mode == :allowlist && hosts.empty?

      hosts = validated_hosts(hosts, field)

      @mode = mode
      @hosts = hosts.freeze
      # Split once, at construction: backends allowlist domains and IP ranges
      # through separate APIs, and a bad entry must fail here, loudly — a
      # malformed allowlist must never launch a sandbox open.
      @ip_targets, @domains = hosts.partition { ip_target?(_1) }.map(&:freeze)
      freeze
    end

    def to_h = { mode: mode, hosts: hosts }

    private

    def validated_hosts(hosts, field)
      hosts.map do |entry|
        raise ConfigError, "#{field}.hosts entry #{entry.inspect} is not a host name, pattern, or IP range" unless entry.is_a?(String) && !entry.strip.empty?

        entry.strip
      end
    end

    def ip_target?(entry)
      IPAddr.new(entry)
      true
    rescue IPAddr::Error
      false
    end
  end
end
