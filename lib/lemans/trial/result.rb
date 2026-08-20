# frozen_string_literal: true

module Lemans
  class Trial
    # What one execution measured: the outcome, the reward, and where the
    # wall clock went.
    class Result
      attr_accessor :status, :reward, :detail, :usage, :agent, :model,
                    :phases, :started_at, :finished_at

      def initialize(agent:, model:)
        @agent = agent
        @model = model
        @status = nil
        @reward = nil
        @detail = nil
        @usage = nil
        @phases = {}
        @started_at = nil
        @finished_at = nil
      end

      def scored? = SCORED.include?(status)

      def invalid? = !scored?

      def duration = finished_at && (finished_at - started_at).round(1)
    end
  end
end
