# frozen_string_literal: true

require "daytona"

module Lemans
  module Environments
    class Daytona
      # Another try for calls whose repeat is free. Only reads qualify: a
      # mutation may have landed server-side before its failure surfaced.
      module Retries
        # The snapshot service leaks the generated client's own error classes
        # instead of wrapping them, so both dialects have to be caught.
        SDK_ERRORS = [ ::Daytona::Sdk::Error, *::Daytona::Sdk::API_ERROR_CLASSES ].freeze

        READ_ATTEMPTS = 3
        RETRY_DELAY_SEC = 2

        private

        def with_read_retries
          attempts = 0
          begin
            yield
          rescue *SDK_ERRORS => e
            attempts += 1
            raise if attempts >= READ_ATTEMPTS || !retryable?(e)

            sleep RETRY_DELAY_SEC
            retry
          end
        end

        # Transport failures surface as status 0 (libcurl stamps refused/reset/
        # DNS with code 0) or none, and throttling and server errors heal on
        # their own; any other 4xx would fail the same way again.
        def retryable?(error)
          status = status_code(error)
          status.nil? || status.zero? || status == 429 || status >= 500
        end

        def status_code(error)
          return error.status_code if error.is_a?(::Daytona::Sdk::Error)

          ::Daytona::Sdk.api_error_details(error)[:status_code]
        end
      end
    end
  end
end
