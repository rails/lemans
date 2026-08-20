# frozen_string_literal: true

module Lemans
  class Config
    # One phase's preparation: the files uploaded into the sandbox and the
    # commands run against them. A bare list is shorthand for commands only.
    class Setup
      class << self
        def from_config(data, root:)
          return if data.nil?

          conf = new
          case data
          when Hash
            conf.commands = Array(data["commands"])
            conf.files = Array(data["files"]).map { file!(it, root:) }
          else
            conf.commands = Array(data)
          end

          conf
        end

        private

        # Files are confined to the directory that declared them and must
        # exist at load time.
        def file!(path, root:)
          raise ConfigError, "setup file #{path.inspect} must be relative to #{root}" if path.start_with?("/")

          relative = Pathname(path).cleanpath
          raise ConfigError, "setup file #{path.inspect} must name a file inside #{root}" if relative.each_filename.include?("..") || relative.to_s == "."
          raise ConfigError, "setup file #{path} is not a file" unless root.join(relative).file?

          [root.join(relative), relative.to_s]
        end
      end

      # Files are [local absolute, remote relative] pairs; commands run in order.
      attr_accessor :files, :commands

      def initialize
        @files = []
        @commands = []
      end

      def merge(other)
        dup.tap do |merged|
          merged.files = files + other.files
          merged.commands = commands + other.commands
        end
      end

      def empty? = files.empty? && commands.empty?
    end
  end
end
