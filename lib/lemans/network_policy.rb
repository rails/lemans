# frozen_string_literal: true

require "ipaddr"

module Lemans
  # What a phase is allowed to reach. Every phase names its policy explicitly:
  #   network: { mode: allowlist, hosts: [openrouter.ai, "*.example.com", 10.0.0.0/8] }
  class NetworkPolicy
    MODES = %i[none allowlist public].freeze

    attr_reader :mode, :hosts

    def self.from_config(config, field:)
      raise ConfigError, "#{field}: network policy is required" if config.nil?

      mode = config["mode"] or raise ConfigError, "#{field}.mode is required (#{MODES.join(", ")})"
      new(mode: mode.to_sym, hosts: config["hosts"] || [], field: field)
    end

    def self.none = new(mode: :none)

    def initialize(mode:, hosts: [], field: "network")
      unless MODES.include?(mode)
        raise ConfigError,
              "#{field}.mode: #{mode.inspect} is not one of #{MODES.join(", ")}"
      end

      if mode != :allowlist && !hosts.empty?
        raise ConfigError,
              "#{field}.hosts is only meaningful with mode: allowlist"
      end

      raise ConfigError, "#{field}.hosts cannot be empty with mode: allowlist" if mode == :allowlist && hosts.empty?

      @mode = mode
      @hosts = hosts.freeze
      @field = field
      freeze
    end

    # Backends allowlist domains and IP ranges through separate APIs; the split happens once here.
    def domains = hosts.reject { ip_target?(_1) }

    def ip_targets = hosts.select { ip_target?(_1) }

    def to_h = { mode: mode, hosts: hosts }

    private

    def ip_target?(entry)
      IPAddr.new(entry.to_s)
      true
    rescue IPAddr::Error
      false
    end
  end
end
