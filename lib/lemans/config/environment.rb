# frozen_string_literal: true

module Lemans
  class Config
    class Environment # :nodoc:
      Resources = Struct.new(:cpus, :memory, :storage, keyword_init: true)
      Profile = Struct.new(:image, :dockerfile, keyword_init: true)

      class << self
        include Conversion

        def from_config(data)
          return if data.nil?

          conf = new
          conf.backend = data["backend"] if data["backend"]
          conf.image = data["image"] if data["image"]
          conf.dockerfile = data["dockerfile"] if data["dockerfile"]

          data["profiles"]&.each { |name, entry| conf.profiles[name] = profile!(name, entry) }

          conf.workdir = absolute_path!(data["workdir"]) if data["workdir"]
          conf.build_timeout = seconds!(data["build_timeout"]) if data["build_timeout"]
          conf.network = NetworkPolicy.from_config(data["network"]) if data["network"]

          conf.resources.cpus = integer!(data.dig("resources", "cpus")) if data.dig("resources", "cpus")
          conf.resources.memory = megabytes!(data.dig("resources", "memory")) if data.dig("resources", "memory")
          conf.resources.storage = megabytes!(data.dig("resources", "storage")) if data.dig("resources", "storage")

          conf
        end

        private

        def profile!(name, entry)
          image, dockerfile = entry&.values_at("image", "dockerfile")
          raise ConfigError, "environment.profiles.#{name}: image and dockerfile are mutually exclusive" if image && dockerfile
          raise ConfigError, "environment.profiles.#{name} must declare image or dockerfile" unless image || dockerfile

          Profile.new(image:, dockerfile:)
        end
      end

      attr_accessor :image, :dockerfile, :workdir, :backend,
                    :resources, :build_timeout, :network, :profiles

      def initialize
        @image = nil
        @dockerfile = nil
        @profiles = {}
        @backend = "daytona"
        @workdir = "/app"
        @resources = Resources.new(cpus: 2, memory: 2048, storage: 5120)
        @build_timeout = 10 * 60
        @network = NetworkPolicy.new
      end

      def to_h
        {
          "backend" => backend,
          "image" => image,
          "dockerfile" => dockerfile&.to_s,
          "profiles" => profiles.transform_values { { "image" => it.image, "dockerfile" => it.dockerfile&.to_s }.compact },
          "workdir" => workdir,
          "build_timeout" => build_timeout,
          "network" => network.to_h,
          "resources" => resources.to_h.transform_keys(&:to_s)
        }.compact
      end
    end
  end
end
