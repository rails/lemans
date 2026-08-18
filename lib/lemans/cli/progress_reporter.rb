# frozen_string_literal: true

module Lemans
  class CLI < Thor
    # The pipe renderer: one plain line per event
    class ProgressReporter
      # say_status's verb column is 12 wide; the longer outcome names get a
      # short verb here and keep their full name in the table and result.json.
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

      def initialize(shell:, task_width:)
        @shell = shell
        @task_width = task_width
      end

      def start = self

      def record(event, data)
        case event
        when :started then started(data)
        when :finished then finished(data)
        when :interrupted
          @shell.say_status :interrupt,
                            "waiting for #{data[:in_flight]} in-flight trial(s), ^C again to abandon", :yellow
        end
      end

      def stop; end

      private

      def started(data)
        attempt = "attempt #{data[:index].to_s.rjust(data[:attempts].to_s.length)}/#{data[:attempts]}"
        @shell.say_status :run, "#{data[:task].to_s.ljust(@task_width)}  #{attempt}  #{data[:trial]}", :blue
      end

      def finished(data)
        detail = data[:scored] ? "reward=#{data[:reward].inspect}" : data[:outcome].to_s
        @shell.say_status STATUS_VERBS.fetch(data[:outcome].to_sym, data[:outcome].to_sym),
                          "#{data[:task].to_s.ljust(@task_width)}  #{detail.ljust(12)}  #{data[:duration_sec]}s",
                          color(data)
      end

      def color(data)
        return :red unless data[:scored]

        data[:reward].to_f >= 1.0 ? :green : :yellow
      end
    end
  end
end
