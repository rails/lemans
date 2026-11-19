# frozen_string_literal: true

require "forwardable"

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

      def_delegators :definition, :name, :config
      def_delegators :result, :id

      private attr_reader :definition, :store, :reporter, :restart_from, :restart_mode, :verification_slots

      def initialize(model, task_definition, index: 0, store: nil, reporter: nil, restart_from: nil, restart_mode: nil,
                     verification_slots: nil)
        @model = model
        @definition = task_definition
        @index = index
        @store = store
        @reporter = reporter
        @restart_from = restart_from
        @restart_mode = restart_mode
        @verification_slots = verification_slots
        @status = :pending

        # prepare the result object: it's used by the actual execution down the stack;
        # a restart keeps the agent of the run it restarts
        @result = Result.from_task(definition, index:, model: model || config.models.first,
                                               **({ agent: restart_from.agent } if restart_from))
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
        store&.save(result) unless result.pending?
      end

      private

      def execute!
        Trial.new(definition, model, store:, result:, agent: restart_from&.agent, restart_from:, restart_mode:,
                                     verification_slots:).run
      end
    end
  end
end
