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

    # The same front door as RestorePaths: refuse the shapes outright instead
    # of trusting a lexical check, and return the cleaned relative path — the
    # raw declared spelling must never become an upload path or a digest key.
    def self.checked(path, phase, root:, label:)
      raise ConfigError, "#{label}: files.#{phase} entry #{path.inspect} is not a path" unless path.is_a?(String) && !path.empty?
      raise ConfigError, "#{label}: files.#{phase} entry #{path.inspect} must be relative to #{root}" if path.start_with?("/")

      relative = Pathname(path).cleanpath
      raise ConfigError, "#{label}: files.#{phase} entry #{path.inspect} must name a file inside #{root}" if relative.each_filename.include?("..") || relative.to_s == "."
      raise ConfigError, "#{label}: files.#{phase} names #{path}, which is not a file" unless root.join(relative).file?

      relative
    end
    private_class_method :checked
  end
end
