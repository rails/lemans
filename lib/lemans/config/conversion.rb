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

      def restore_path!(path)
        raise ConfigError, "restore path must be workdir-relative, got #{path.inspect}" if path.start_with?("/")
        raise ConfigError, "restore path must not escape the workdir: #{path.inspect}" if path.split("/").include?("..")
        raise ConfigError, "restore path must name something inside the workdir, got #{path.inspect}" if Pathname(path).cleanpath.to_s == "."

        path
      end

      SETUP_PHASES = %i[environment verifier].freeze

      # Setup files are confined to the directory that declared them and must
      # exist at load time.
      def setup_files!(declared, root:)
        declared ||= {}
        unknown = declared.keys.map(&:to_sym) - SETUP_PHASES
        raise ConfigError, "files.#{unknown.first} is not a phase (#{SETUP_PHASES.join(", ")})" if unknown.any?

        root = Pathname(root)
        SETUP_PHASES.to_h do |phase|
          [phase, Array(declared[phase.to_s]).map { setup_file!(it, phase, root:) }]
        end
      end

      def setup_file!(path, phase, root:)
        raise ConfigError, "files.#{phase} entry #{path.inspect} must be relative to #{root}" if path.start_with?("/")

        relative = Pathname(path).cleanpath
        raise ConfigError, "files.#{phase} entry #{path.inspect} must name a file inside #{root}" if relative.each_filename.include?("..") || relative.to_s == "."
        raise ConfigError, "files.#{phase} names #{path}, which is not a file" unless root.join(relative).file?

        relative
      end
    end
  end
end
