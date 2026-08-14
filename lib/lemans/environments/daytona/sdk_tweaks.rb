# frozen_string_literal: true

require "daytona"
require "logger"

module Lemans
  module Environments
    class Daytona
      # Repairs the Daytona SDK needs to be usable from a harness. Upstream ask: per-request
      # timeouts like the Python SDK's — tracked in tmp/upstream-daytona-sdk-timeouts.md.
      module SdkTweaks
        GENERATED_CLIENTS = [
          ::DaytonaApiClient, ::DaytonaToolboxApiClient, ::DaytonaAnalyticsApiClient
        ].freeze

        # Must clear the longest request: an exec long-polling server-side for SHORT_COMMAND_SEC.
        # Also caps fs uploads/downloads and execs with no timeout — fine for scripts and logs.
        HTTP_TIMEOUT_SEC = Shell::SHORT_COMMAND_SEC + 30

        # The clients default to timeout=0, libcurl's "never time out"; a dropped connection then
        # parks a thread no Thread#kill reclaims. Only that 0 is replaced; explicit config wins.
        module Deadline
          def timeout
            value = super
            value&.zero? ? HTTP_TIMEOUT_SEC : value
          end
        end

        # `.configure` is broken — it sets a default config the SDK never reads — and `Sdk.logger`
        # memoizes with no writer, so both are silenced by hand.
        module Quiet
          NULL_LOGGER = Logger.new(IO::NULL)

          def logger = NULL_LOGGER
        end

        def self.apply!
          GENERATED_CLIENTS.each { _1::Configuration.prepend(Deadline) }
          return if ENV["DEBUG_DAYTONA"] == "1"

          GENERATED_CLIENTS.each { _1::Configuration.prepend(Quiet) }
          ::Daytona::Sdk.instance_variable_set(:@logger, Quiet::NULL_LOGGER)
        end
      end
    end
  end
end
