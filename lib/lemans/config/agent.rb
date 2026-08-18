# frozen_string_literal: true

module Lemans
  class Config
    class Agent # :nodoc:
      class << self
        include Conversion

        def from_config(data)
          name = data.fetch("name")
          model = data.fetch("model")

          conf = new(name, model)

          conf.step_limit = integer!(data["step_limit"]) if data["step_limit"]
          conf.cost_limit = float!(data["cost_limit"]) if data["cost_limit"]
          conf.timeout = seconds!(data["timeout"]) if data["timeout"]
          conf.exec_timeout = seconds!(data["exec_timeout"]) if data["exec_timeout"]

          if (network_data = data.dig("environment", "network"))
            conf.environment = Environment.new(network: NetworkPolicy.from_config(network_data))
          end

          conf
        rescue KeyError => e
          raise ConfigError, "agent.#{e.key} must be provided"
        end
      end

      attr_accessor :name, :models, :timeout,
                    :step_limit, :cost_limit, :exec_timeout,
                    :environment

      Environment = Data.define(:network)

      def initialize(name, model)
        @name = name
        @models = Array(model)
        @step_limit = 100
        @cost_limit = nil
        @exec_timeout = 300
        @timeout = 30 * 60
        @environment = Environment.new(network: NetworkPolicy.new)
      end
    end
  end
end
