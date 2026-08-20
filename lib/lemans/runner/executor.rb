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
          Thread.new { drain }
        end
        results
      end

      def <<(task)
        queue << task
      end

      def terminate
        queue.clear
        queue.close
        pool.each { it.raise(Shutdown) if it.alive? }
        pool.each(&:join)
      end

      def shutdown
        queue.close
        pool.each(&:join)
        raise @abort if @abort
      end

      private

      def drain
        Thread.current.report_on_exception = false
        while (task = queue.pop)
          begin
            results.buffer << task.run
          rescue StandardError => e
            @abort ||= e
            queue.clear
            queue.close
          end
        end
      rescue Shutdown
        # ignore: our own stop signal coming back
      end
    end
  end
end
