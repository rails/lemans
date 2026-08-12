# frozen_string_literal: true

require "daytona"
require "logger"

module Lemans
  module Environments
    class Daytona
      # Every repair the Daytona SDK needs to be usable from a harness, in one
      # place, so a fixed SDK deletes a file instead of starting a scavenger
      # hunt. Upstream ask: per-request timeouts like the Python SDK's
      # `_request_timeout` — tracked in tmp/upstream-daytona-sdk-timeouts.md.
      module SdkTweaks
        GENERATED_CLIENTS = [
          ::DaytonaApiClient, ::DaytonaToolboxApiClient, ::DaytonaAnalyticsApiClient
        ].freeze

        # Sized to clear the longest request lemans makes: an exec
        # long-polling server-side for SHORT_COMMAND_SEC, with the margin the
        # Python SDK uses (`timeout + 5`, generously). Known casualties, both
        # fine today: fs.upload_file/download_file share this cap (our files
        # are scripts and logs — revisit for benches with big artifacts), and
        # an exec with no timeout_sec is no longer unbounded.
        HTTP_TIMEOUT_SEC = Shell::SHORT_COMMAND_SEC + 30

        # The generated clients default to `timeout = 0` — libcurl's "never
        # time out" — so a silently dropped connection parks its thread
        # forever, and the FFI call has no unblock function, so not even
        # Thread#kill reclaims it. Only that 0 is replaced; a deliberately
        # configured deadline wins. Log streaming is unaffected: it rides
        # Net::HTTP, not these clients.
        module Deadline
          def timeout
            value = super
            value&.zero? ? HTTP_TIMEOUT_SEC : value
          end
        end

        # `DaytonaApiWhatever.configure` is broken — it configures a default
        # config the SDK never reads — and `Sdk.logger` memoizes with
        # `@logger ||=` and has no writer, so both are silenced by hand.
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
