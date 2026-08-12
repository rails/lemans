# frozen_string_literal: true

module Lemans
  module Results
    # Why a trial ended, and whether its reward means anything: out-of-budget
    # is a scored failure, a sandbox that never started measured nothing.
    class Outcome
      SCORED = %i[completed agent_timeout step_limit_reached cost_ceiling_reached].freeze
      INVALID = %i[environment_error agent_error accounting_error verifier_error cancelled harness_crash].freeze

      ALL = (SCORED + INVALID).freeze

      attr_reader :name, :detail

      def initialize(name, detail: nil)
        raise ArgumentError, "unknown outcome #{name.inspect}" unless ALL.include?(name)

        @name = name
        @detail = detail
        freeze
      end

      ALL.each do |outcome|
        define_method(:"#{outcome}?") { name == outcome }
      end

      def scored? = SCORED.include?(name)

      def invalid? = !scored?

      def to_h = { name: name, scored: scored?, detail: detail }.compact

      def to_s = detail ? "#{name}: #{detail}" : name.to_s
    end
  end
end
