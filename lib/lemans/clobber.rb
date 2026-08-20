# frozen_string_literal: true

module Lemans
  # Deletes stored results based on the provided filters.
  class Clobber
    include Config::Conversion

    private attr_reader :store, :tasks, :ttl, :invalid

    def initialize(store, tasks: [], ttl: nil, invalid: false)
      @store = store
      @tasks = Array(tasks)
      @ttl = ttl && seconds!(ttl)
      @invalid = invalid
    end

    def matches
      @matches ||= select_matches
    end

    def execute!
      matches.select { store.delete(it) }
    end

    private

    def select_matches
      candidates = store.fetch
      candidates += store.unreadable if invalid

      matched = candidates.select do |result|
        (tasks.empty? || tasks.include?(result.task)) &&
          (ttl.nil? || age(result) > ttl) &&
          (!invalid || result.invalid?)
      end
      matched.sort_by { it.id.to_s }
    end

    def age(result) = result.finished_at ? Time.now.utc - result.finished_at : Float::INFINITY
  end
end
