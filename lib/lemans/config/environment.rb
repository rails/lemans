# frozen_string_literal: true

module Lemans
  class Config
    class Environment # :nodoc:
      Resources = Struct.new(:cpus, :memory_mb, :storage_mb, keyword_init: true)

      class << self
        include Conversion

        def from_config(data)
          return if data.nil?

          conf = new
          conf.image = data["image"] if data["image"]
          conf.workdir = absolute_path!(data["workdir"]) if data["workdir"]
          conf.build_timeout = seconds!(data["build_timeout"]) if data["build_timeout"]
          conf.network = NetworkPolicy.from_config(data["network"]) if data["network"]
          conf.setup = Array(data["setup"]) if data["setup"]

          conf.resources.cpus = integer!(data.dig("resources", "cpus")) if data.dig("resources", "cpus")
          conf.resources.memory_mb = megabytes!(data.dig("resources", "memory")) if data.dig("resources", "memory")
          conf.resources.storage_mb = megabytes!(data.dig("resources", "storage")) if data.dig("resources", "storage")

          conf
        end
      end

      attr_accessor :image, :workdir, :resources, :build_timeout, :network, :setup

      def initialize
        @image = nil
        @workdir = "/app"
        @resources = Resources.new(cpus: 2, memory_mb: 2048, storage_mb: 5120)
        @build_timeout = 10 * 60
        @network = NetworkPolicy.new
        @setup = []
      end
    end
  end
end
