# frozen_string_literal: true

module Lemans
  module Results
    # One sorting rule for every results view: validate the column name and
    # keep rows that never measured the value at the bottom.
    module Sorting
      def self.column(name, allowed:)
        column = name.to_s.to_sym
        return column if allowed.include?(column)

        raise ConfigError, "--sort: unknown column #{name.inspect} (try #{allowed.join(", ")})"
      end

      def self.call(rows, descending: false)
        keyed = rows.map { [yield(_1), _1] }
        present, missing = keyed.partition { |value, _| value }
        sorted = present.sort_by { |value, _| value }
        sorted.reverse! if descending
        (sorted + missing).map(&:last)
      end
    end
  end
end
