# frozen_string_literal: true

module Lemans
  module Results
    # One definition of the numbers everyone quotes — how many trials, how
    # many measured anything, how many solved — so the streaming summary and
    # the report can never drift apart.
    module Tally
      def self.call(entries)
        scored = entries.count { _1[:scored] }
        {
          total: entries.size,
          scored: scored,
          invalid: entries.size - scored,
          solved: entries.count { _1[:reward].to_f >= 1.0 }
        }
      end
    end
  end
end
