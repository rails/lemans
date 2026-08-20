# frozen_string_literal: true

require "pathname"

module Lemans
  class Config
    # Helper methods to parse/convert config-provided values
    module Conversion
      DURATION = /\A(\d+(?:\.\d+)?)\s*(ms|s|m|h|d)?\z/
      DURATION_FACTORS = { "ms" => 0.001, "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

      SIZE = /\A(\d+(?:\.\d+)?)\s*(MB|GB|TB)?\z/i
      SIZE_FACTORS = { "mb" => 1, "gb" => 1024, "tb" => 1024 * 1024 }.freeze

      def integer!(value)
        Integer(value)
      rescue ArgumentError, TypeError
        raise ConfigError, "cannot read #{value.inspect} as an integer"
      end

      def float!(value)
        Float(value)
      rescue ArgumentError, TypeError
        raise ConfigError, "cannot read #{value.inspect} as a number"
      end

      def seconds!(value)
        if value.is_a?(Numeric)
          raise ConfigError, "duration must be non-negative, got: #{value}" if value.negative?

          return value
        end

        match = DURATION.match(value.to_s.strip)

        raise ConfigError, "cannot read #{value.inspect} as a duration (try 30m, 300s, 1h)" unless match

        match[1].to_f * DURATION_FACTORS.fetch(match[2] || "s")
      end

      def megabytes!(value)
        if value.is_a?(Numeric)
          raise ConfigError, "size must be non-negative, got: #{value}" if value.negative?

          return value.round
        end

        match = SIZE.match(value.to_s.strip)

        raise ConfigError, "cannot read #{value.inspect} as a size (try 2GB, 512MB)" unless match

        (match[1].to_f * SIZE_FACTORS.fetch((match[2] || "mb").downcase)).round
      end

      def absolute_path!(value)
        raise ConfigError, "#{value.inspect} is not an absolute path" unless value.start_with?("/")

        value
      end
    end
  end
end
