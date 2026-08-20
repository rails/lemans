# frozen_string_literal: true

module Lemans
  class Runner
    # A single task to run: a thin wrapper owning status, reporting, and
    # result persistence; the actual work is the Trial's.
    class Task
      extend Forwardable

      attr_reader :model, :index, :status, :result

      RUN_STATUSES = %i[pending running finished].freeze

      RUN_STATUSES.each do |name|
        define_method(:"#{name}?") { status == name }
      end

      def_delegators :name, :config, to: :definition

      private attr_reader :definition, :store, :reporter

      def initialize(model, task_definition, index: 0, store: nil, reporter: nil)
        @model = model
        @definition = task_definition
        @index = index
        @store = store
        @reporter = reporter
        @status = :pending

        # prepare the result object: it's used by the actual execution down the stack
        @result = Result.from_task(definition)
      end

      def with_reporter(reporter)
        @reporter = reporter
        self
      end

      def run
        @status = :running
        reporter&.record(:started, self)

        execute!

        @status = :finished
        reporter&.record(:finished, result)
        result
      ensure
        store&.save(result)
      end

      private

      def execute!
        Trial.new(definition, store:, result:).run
      end
    end
  end
end
