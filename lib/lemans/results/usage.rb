# frozen_string_literal: true

module Lemans
  module Results
    # What a trial spent. Cache tokens count separately, and the cost carries
    # its own provenance — $0.00 is the figure most in need of auditing.
    Usage = Data.define(:input_tokens, :output_tokens, :cached_tokens, :cost_usd, :steps, :cost_source) do
      def self.zero
        new(input_tokens: 0, output_tokens: 0, cached_tokens: 0, cost_usd: 0.0, steps: 0, cost_source: CostSource.none)
      end

      def to_h
        {
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cached_tokens: cached_tokens,
          cost_usd: cost_usd,
          steps: steps,
          cost_source: cost_source&.to_h
        }
      end
    end
  end
end
