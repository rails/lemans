# frozen_string_literal: true

module Lemans
  class Runner
    # A single task to run
    class Task
      attr_reader :index
      private attr_reader :model, :task, :reporter

      def initialize(model, task, index: 0, reporter: nil)
        @model = model
        @task = task
        @index = index
        @reporter = reporter
      end

      def with_reporter(reporter)
        @reporter = reporter
        self
      end

      def run
        # TODO: implement me
      end
    end
  end
end
