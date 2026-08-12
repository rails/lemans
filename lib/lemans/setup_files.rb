# frozen_string_literal: true

require "pathname"

module Lemans
  # The files a phase's setup steps consume. Paths are confined to the
  # directory that declared them and must exist at load time.
  module SetupFiles
    PHASES = %i[environment verifier].freeze

    def self.call(declared, root:, label:)
      declared ||= {}
      raise ConfigError, "#{label}: files must name a phase (#{PHASES.join(", ")})" unless declared.is_a?(Hash)

      unknown = declared.keys.map(&:to_s) - PHASES.map(&:to_s)
      raise ConfigError, "#{label}: files.#{unknown.first} is not a phase (#{PHASES.join(", ")})" if unknown.any?

      root = Pathname(root)
      PHASES.to_h do |phase|
        [phase, Array(declared[phase.to_s]).map { checked(_1, phase, root: root, label: label) }.freeze]
      end.freeze
    end

    def self.checked(path, phase, root:, label:)
      relative = Pathname(path.to_s)
      resolved = root.join(relative).cleanpath

      unless resolved.to_s.start_with?("#{root.cleanpath}/")
        raise ConfigError, "#{label}: files.#{phase} entry #{path.inspect} points outside #{root}"
      end
      raise ConfigError, "#{label}: files.#{phase} names #{path}, which is not a file" unless resolved.file?

      relative
    end
    private_class_method :checked
  end
end
