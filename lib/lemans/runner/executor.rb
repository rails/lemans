# frozen_string_literal: true

require "concurrent"

module Lemans
  class Runner
    # A default (Threaded) concurrent executor for tasks
    class Executor
      Results = Data.define(:buffer) do
        def results = buffer.to_a
      end

      private attr_reader :concurrency, :queue, :results, :pool

      def initialize(concurrency)
        @concurrency = concurrency
        @queue = Queue.new
        @results = Results.new(Concurrent::Array.new)
        @pool = nil
      end

      def start
        @pool = Array.new(concurrency) do
          Thread.new(queue, results) do |q, r|
            Thread.current.abort_on_exception = false
            drain(q, r)
          end
        end
        results
      end

      def <<(task)
        queue << task
      end

      def terminate
        pool.each { it.raise(Shutdown) }
      end

      def shutdown
        concurrency.times { queue << nil }
        queue.close
        pool.each(&:join)
      end

      private

      def drain(from, where)
        while (task = from.pop)
          break unless task

          where << task.run
        end
      end
    end
  end
end
