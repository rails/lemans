# frozen_string_literal: true

require "securerandom"
require "time"

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

      def invalid? = !scored

      def as_json(**)
        {
          name:,
          scored:,
          detail:
        }.compact
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
    ) do
      def as_json(**) = to_h.merge(cost_source: cost_source&.to_h).compact

      # A multistep trial's totals; an unknown step cost makes the sum unknown.
      def +(other)
        self.class.new(
          input_tokens: input_tokens + other.input_tokens,
          output_tokens: output_tokens + other.output_tokens,
          cached_tokens: cached_tokens + other.cached_tokens,
          steps: steps + other.steps,
          cost_usd: cost_usd && other.cost_usd && cost_usd + other.cost_usd,
          cost_source: other.cost_source || cost_source
        )
      end
    end

    def Usage.zero
      new(input_tokens: 0, output_tokens: 0, cached_tokens: 0, steps: 0, cost_usd: 0.0, cost_source: nil)
    end

    def Usage.from_json(data)
      # Older files carry a partial cost_source (just the name).
      if (source = data[:cost_source])
        cost_source = CostSource.new(**CostSource.members.to_h { [ it, nil ] }, **source)
      end
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
        @name = name.to_sym
        @started_at = started_at || Time.now.utc
        @finished_at = finished_at
      end

      def finish!(time = nil)
        @finished_at = time || Time.now.utc
      end

      def duration = finished_at && (finished_at - started_at).round(1)

      def as_json(**)
        {
          name:,
          started_at: started_at.iso8601(6),
          finished_at: finished_at&.iso8601(6)
        }
      end

      def self.from_json(data)
        name, started_at_str, finished_at_str = data.values_at(:name, :started_at, :finished_at)

        started_at = Time.parse(started_at_str) if started_at_str
        finished_at = Time.parse(finished_at_str) if finished_at_str

        new(name, started_at:, finished_at:)
      end
    end

    Revision = Data.define(:commit, :dirty) do
      def as_json(**) = to_h
    end

    Step = Data.define(:outcome, :usage, :duration) do
      def as_json(**) = { outcome: outcome.as_json, usage: usage&.as_json, duration: }.compact

      def self.from_json(data)
        new(outcome: Outcome.from_json(data[:outcome]),
            usage: data[:usage] && Usage.from_json(data[:usage]),
            duration: data[:duration])
      end
    end

    # attributes that must be initialized/specified during construction
    attr_reader :id, :task, :agent, :model, :index,
                :profile_digest, :task_digest, :revision

    attr_accessor :tags, :metadata

    attr_reader :phases, :steps

    # outcome-related attributes (we use setter-like methods, not accessors)
    attr_reader :reward, :outcome, :usage

    def initialize(task:, agent:, model:, id: nil, index: nil,
                   profile_digest: nil, task_digest: nil, revision: nil)
      @task = task
      @agent = agent
      @model = model
      @index = index
      @profile_digest = profile_digest
      @task_digest = task_digest
      @revision = revision

      @tags = []
      @metadata = {}
      @phases = []
      @steps = nil

      @id = id || "#{task}__#{SecureRandom.alphanumeric(7)}"
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

    def status = outcome.status

    def detail = outcome.detail

    def pending? = outcome.pending?

    def scored? = outcome.scored?

    def invalid? = outcome.invalid?

    def duration
      @duration || (finished_at && started_at && (finished_at - started_at).round(1))
    end

    def completed!(outcome, usage = nil, duration: nil)
      @outcome = outcome.is_a?(Outcome) ? outcome : Outcome.new(outcome)
      @usage = usage
      @duration = duration if duration
      self
    end

    def step_completed!(outcome, usage = nil, duration: nil)
      outcome = outcome.is_a?(Outcome) ? outcome : Outcome.new(outcome)
      @steps ||= []
      steps << Step.new(outcome:, usage:, duration:)
      # aggregate right away (so we don't lose data on failure)
      completed!(outcome, aggregate_usage)
    end

    def graded!(reward)
      @reward = reward
      self
    end

    def failed!(reason, detail)
      # do not override already stored error
      # (in case we have rescue cascades)
      return self if outcome.invalid? && !outcome.pending?

      @outcome = Outcome.new(reason, detail)
      @reward = nil
      self
    end

    private def aggregate_usage = steps.filter_map(&:usage).reduce(:+)

    def as_json(**)
      {
        trial: id, task:, agent:, model:, index:,
        profile_digest:, task_digest:, revision: revision&.as_json,
        lemans_version: VERSION,
        tags:, metadata:, phases: phases.map(&:as_json),
        steps: steps&.map(&:as_json),
        reward:, outcome: outcome.as_json, usage: usage&.as_json, duration:,
        started_at: started_at&.iso8601,
        finished_at: finished_at&.iso8601
      }.compact
    end

    class << self
      def from_json(data)
        result = new(
          **data.slice(:task, :agent, :model, :index, :profile_digest, :task_digest),
          # 0.2.x releases spell the id `run:`.
          id: data[:trial] || data[:run],
          revision: revision_from(data)
        )
        result.tags = data[:tags] || []
        result.metadata = data[:metadata] || {}
        phases_from(data).each { result.phases << it }
        # Steps first: the stored outcome/usage below override the aggregates.
        data[:steps]&.map { Step.from_json(it) }&.each do |step|
          result.step_completed!(step.outcome, step.usage, duration: step.duration)
        end
        if data[:outcome]
          result.completed!(
            Outcome.from_json(data[:outcome]),
            data[:usage] && Usage.from_json(data[:usage]),
            # The recorded duration wins over the one derived from phases:
            # older writers timed a slightly wider span.
            duration: data[:duration] || data[:duration_sec]
          )
        end
        result.graded!(data[:reward]) unless data[:reward].nil?
        result
      end

      def from_task(definition, **)
        config = definition.config
        result = new(
          task: definition.name,
          agent: config.agent_name,
          model: config.models.first,
          profile_digest: config.digest,
          task_digest: definition.digest,
          revision: config.revision,
          **
        )
        result.tags = definition.tags
        result.metadata = definition.metadata
        result
      end

      private

      # Legacy files spell revision `bench:`.
      def revision_from(data)
        raw = data[:revision] || data[:bench]
        raw && Revision.new(commit: raw[:commit], dirty: raw[:dirty])
      end

      # Legacy files record phases as a name-keyed mapping.
      def phases_from(data)
        case (raw = data[:phases])
        when Hash then raw.map { |name, times| Phase.from_json({ name: }.merge(times)) }
        when Array then raw.map { Phase.from_json(it) }
        else []
        end
      end
    end
  end
end
