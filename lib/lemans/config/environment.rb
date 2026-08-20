# frozen_string_literal: true

require "pathname"

module Lemans
  class Config
    class Environment # :nodoc:
      Resources = Struct.new(:cpus, :memory, :storage, keyword_init: true)

      class << self
        include Conversion

        def from_config(data, root: Pathname("./"))
          return if data.nil?

          conf = new
          conf.image = data["image"] if data["image"]
          conf.dockerfile = dockerfile!(data["dockerfile"], root:) if data["dockerfile"]
          raise ConfigError, "environment.image and environment.dockerfile are mutually exclusive" if conf.image && conf.dockerfile

          conf.workdir = absolute_path!(data["workdir"]) if data["workdir"]
          conf.build_timeout = seconds!(data["build_timeout"]) if data["build_timeout"]
          conf.network = NetworkPolicy.from_config(data["network"]) if data["network"]

          conf.resources.cpus = integer!(data.dig("resources", "cpus")) if data.dig("resources", "cpus")
          conf.resources.memory = megabytes!(data.dig("resources", "memory")) if data.dig("resources", "memory")
          conf.resources.storage = megabytes!(data.dig("resources", "storage")) if data.dig("resources", "storage")

          conf
        end

        private

        def dockerfile!(path, root:)
          raise ConfigError, "environment.dockerfile must be relative to #{root}, got #{path.inspect}" if path.start_with?("/")

          file = root.join(path)
          raise ConfigError, "no Dockerfile at #{file}" unless file.file?

          file
        end
      end

      attr_accessor :image, :dockerfile, :workdir, :resources, :build_timeout, :network

      def initialize
        @image = nil
        @dockerfile = nil
        @workdir = "/app"
        @resources = Resources.new(cpus: 2, memory: 2048, storage: 5120)
        @build_timeout = 10 * 60
        @network = NetworkPolicy.new
      end
    end
  end
end
