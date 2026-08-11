# frozen_string_literal: true

module Lemans
  module Corpus
    # Durations and sizes as a human writes them ("30m", "2GB"), stored as
    # seconds and megabytes. A bare number gets the obvious reading.
    module Units
      DURATION = /\A(\d+(?:\.\d+)?)\s*(ms|s|m|h)?\z/
      DURATION_FACTORS = { "ms" => 0.001, "s" => 1, "m" => 60, "h" => 3600 }.freeze

      SIZE = /\A(\d+(?:\.\d+)?)\s*(MB|GB|TB)?\z/i
      SIZE_FACTORS = { "mb" => 1, "gb" => 1024, "tb" => 1024 * 1024 }.freeze

      class << self
        def seconds(value, field:)
          return nil if value.nil?
          return value.to_f if value.is_a?(Numeric)

          match = DURATION.match(value.to_s.strip)
          raise ConfigError, "#{field}: cannot read #{value.inspect} as a duration (try 30m, 300s, 1h)" unless match

          match[1].to_f * DURATION_FACTORS.fetch(match[2] || "s")
        end

        def megabytes(value, field:)
          return nil if value.nil?
          return value.to_i if value.is_a?(Numeric)

          match = SIZE.match(value.to_s.strip)
          raise ConfigError, "#{field}: cannot read #{value.inspect} as a size (try 2GB, 512MB)" unless match

          (match[1].to_f * SIZE_FACTORS.fetch((match[2] || "mb").downcase)).round
        end
      end
    end
  end
end
