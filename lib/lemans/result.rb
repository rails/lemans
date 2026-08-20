# frozen_string_literal: true

require "securerandom"

module Lemans
  # A single trial result record
  class Result
    class IncompatibleError < StandardError
    end

    class Outcome # :nodoc:
      SCORED = %i[completed agent_timeout step_limit_reached cost_ceiling_reached].freeze
      INVALID = %i[environment_error agent_error accounting_error verifier_error cancelled pending harness_crash].freeze

      ALL = (SCORED + INVALID).freeze

      ALL.each do |outcome|
        define_method(:"#{outcome}?") { name == outcome }
      end

      attr_reader :status, :scored, :detail

      # backward-compat
      alias name status

      alias scored? scored

      def initialize(status, detail = nil)
        status = status.to_sym
        raise IncompatibleError, "Unrecognized outcome: #{status}" unless ALL.include?(status)

        @status = status
        @detail = detail
        @scored = SCORED.include?(status)
      end

      def invalid? = INVALID.include?(status)

      def as_json(**)
        {
          name:,
          scored:,
          detail:
        }
      end

      def self.from_json(data)
        status, detail = data.values_at(:name, :detail)
        new(status, detail)
      end
    end

    CostSource = Data.define(:name, :model, :priced_as, :registry)

    Usage = Data.define(
      :input_tokens, :output_tokens,
      :cached_tokens, :steps,
      :cost_usd, :cost_source
    )

    def Usage.from_json(data)
      cost_source = CostSource.new(**data[:cost_source]) if data[:cost_source]
      new(
        input_tokens: data[:input_tokens],
        output_tokens: data[:output_tokens],
        cached_tokens: data[:cached_tokens],
        steps: data[:steps],
        cost_usd: data[:cost_usd],
        cost_source:
      )
    end

    class Phase # :nodoc:
      attr_reader :name, :started_at, :finished_at

      alias finished? finished_at

      def initialize(name, started_at: nil, finished_at: nil)
        @name = name
        @started_at = started_at || now
        @finished_at = finished_at
      end

      def finish!(time = nil)
        @finished_at = time || now
      end

      def as_json(**)
        {
          started_at: Time.at(started_at).utc.iso8601,
          finished_at: finished_at && Time.at(finished_at).utc.iso8601
        }
      end

      def self.from_json(data)
        name, started_at_str, finished_at_str = data.values_at(:name, :started_at, :finished_at)

        started_at = Time.parse(started_at_str) if started_at_str
        finished_at = Time.parse(finished_at_str) if finished_at_str

        new(name, started_at:, finished_at:)
      end

      private

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    Revision = Data.define(:commit, :dirty)

    # attributes that must be initialized/specified during construction
    attr_reader :id, :task, :agent, :model,
                :profile_digest, :task_digest,
                :tags, :metadata, :phases, :revision

    # outcome-related attributes (we use setter-like methods, not accessors)
    attr_reader :reward, :outcome, :usage, :duration

    private attr_reader :finalized

    def initialize(task:, agent:, model:, id: nil, profile_digest: nil, task_digest: nil, revision: nil)
      @id = id || "#{task}__#{SecureRandom.alphanumeric(7)}"
      @task = task
      @agent = agent
      @model = model
      @profile_digest = profile_digest
      @task_digest = task_digest
      @revision = revision

      @tags = []
      @metadata = {}
      @phases = []

      @outcome = Outcome.new(:pending)
    end

    def phase_started(name, started_at = nil)
      raise ArgumentError, "previous phase hasn't finished yet" if phases.last && !phases.last.finished?

      phases << Phase.new(name, started_at:)
    end

    def phase_finished(name, finished_at = nil)
      raise ArgumentError, "no current phase" if phases.empty?
      raise ArgumentError, "can not finish phase #{name}: current one is #{phases.last.name}" if phases.last.name != name

      phases.last.finish!(finished_at)
    end

    def started_at = phases.first&.started_at

    def finished_at = phases.last&.finished_at

    def scored? = outcome.scored?

    def completed!(outcome, usage = nil)
      @outcome = outcome.is_a?(Outcome) ? outcome : Outcome.new(outcome)
      @usage = usage
      self
    end

    def graded!(reward)
      @reward = reward
      self
    end

    def failed!(reason, detail)
      # do not override already stored error
      # (in case we have rescue cascades)
      return if outcome.invalid?

      @outcome = Outcome.new(reason, detail)
      @reward = nil
      self
    end

    def as_json(**)
      {
        trial: id, task:, agent:, model:,
        profile_digest:, task_digest:, revision:,
        tags:, metadata:, phases:,
        reward:, outcome:, usage:, duration:,
        started_at: started_at && Time.at(started_at).utc.iso8601,
        finished_at: finished_at && Time.at(finished_at).utc.iso8601
      }
    end

    def self.from_json(data)
      new(
        **data.slice(
          :task, :agent,
          :model, :profile_digest, :task_digest,
          :tags, :metadata,
          :reward, :duration
        ),
        id: data[:trial],
        revision: data[:revision] && Revision.new(**data[:revision]),
        outcome: data[:outcome] && Outcome.from_json(data[:outcome]),
        phases: data[:phases]&.map { Phase.from_json(it) },
        usage: Usage.from_json(data[:usage])
      )
    end

    def self.from_task(definition, **)
      new(
        task: definition.name,
        agent: definition.config.agent_name,
        model: definition.config.models.first,
        profile_digest: definition.config.digest,
        task_digest: definition.digest,
        **
      )
    end
  end
end
