# frozen_string_literal: true

module Lemans
  class CLI < Thor
    # The pipe renderer: one plain line per event
    class ProgressReporter
      # say_status's verb column is 12 wide; the longer status names get a
      # short verb here and keep their full name in the board and the result.
      STATUS_VERBS = {
        completed: :completed,
        agent_timeout: :timeout,
        step_limit_reached: :step_limit,
        cost_ceiling_reached: :cost_limit,
        environment_error: :invalid,
        agent_error: :invalid,
        accounting_error: :invalid,
        verifier_error: :invalid,
        harness_crash: :invalid
      }.freeze

      MAX_DETAIL_CHARS = 200

      def initialize(shell:, tasks:)
        @shell = shell
        @task_width = (tasks.map(&:length) + [ 4 ]).max
      end

      def start = self

      def record(event, data = nil)
        case event
        when :started then started(data)
        when :finished then finished(data)
        when :interrupted
          @shell.say_status :interrupt, "abandoning in-flight trial(s)", :yellow
        end
      end

      def stop; end

      private

      def started(task)
        attempts = task.config.attempts
        attempt = "attempt #{task.index.to_s.rjust(attempts.to_s.length)}/#{attempts}"
        @shell.say_status :run, "#{task.name.ljust(@task_width)}  #{attempt}  #{task.id}", :blue
      end

      def finished(result)
        status = result.scored? ? "reward=#{result.reward.inspect}" : result.status.to_s
        @shell.say_status STATUS_VERBS.fetch(result.status, result.status),
                          "#{result.task.ljust(@task_width)}  #{status.ljust(12)}  #{result.duration}s",
                          color(result)

        @shell.say_status :error, first_line(result.detail), :red unless result.scored? || result.detail.nil?
      end

      def first_line(detail) = detail.to_s.lines.first.to_s.strip[0, MAX_DETAIL_CHARS]

      def color(result)
        return :red unless result.scored?

        result.reward.to_f >= 1.0 ? :green : :yellow
      end
    end
  end
end
