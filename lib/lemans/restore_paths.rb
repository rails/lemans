# frozen_string_literal: true

require "pathname"

module Lemans
  module RestorePaths # :nodoc:
    def self.call(declared, label:)
      Array(declared).each_with_index.map do |path, index|
        entry = "#{label}[#{index}]"
        raise ConfigError, "#{entry} must be a path string, got #{path.inspect}" unless path.is_a?(String)
        raise ConfigError, "#{entry} must be workdir-relative, got #{path.inspect}" if path.start_with?("/")
        raise ConfigError, "#{entry} must not escape the workdir: #{path.inspect}" if
          path.split("/").include?("..")
        raise ConfigError, "#{entry} must name something inside the workdir, got #{path.inspect}" if
          Pathname(path).cleanpath.to_s == "."

        path
      end.freeze
    end
  end
end
