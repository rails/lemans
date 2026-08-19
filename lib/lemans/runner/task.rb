# frozen_string_literal: true

require "securerandom"

module Lemans
  class Runner
    # A single task to run
    class Task
      attr_reader :model, :index, :status, :result

      private attr_reader :task, :reporter

      def initialize(model, task, index: 0, reporter: nil)
        @model = model
        @task = task
        @index = index
        @reporter = reporter
        @status = :pending
        @result = nil
      end

      def id
        @id ||= "#{name}__#{SecureRandom.alphanumeric(7)}"
      end

      def name = task.name

      def config = task.config

      def pending? = status == :pending

      def running? = status == :running

      def finished? = status == :finished

      def with_reporter(reporter)
        @reporter = reporter
        self
      end

      def run
        @status = :running
        reporter&.record(:started, self)
        @result = execute
        @status = :finished
        reporter&.record(:finished, result)
        result
      end

      private

      def execute
        # TODO: implement me
      end
    end
  end
end
