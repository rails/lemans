# frozen_string_literal: true

require "test_helper"
require "json"

class ResultTest < Minitest::Test
  def build_result(**) = Lemans::Result.new(task: "hello-world", agent: "oracle", model: "m/model-a", index: 1, **)

  def test_lifecycle
    result = build_result

    assert_predicate result.outcome, :pending?
    assert_predicate result, :invalid?

    result.phase_started(:agent)
    result.phase_finished(:agent)
    result.completed!(:completed, Lemans::Result::Usage.zero)
    result.graded!(0.5)

    assert_predicate result, :scored?
    assert_equal :completed, result.status
    assert_in_delta 0.5, result.reward
    assert_kind_of Float, result.duration
  end

  def test_failures_do_not_cascade
    result = build_result
    result.failed!(:agent_error, "first")
    result.failed!(:environment_error, "second")

    assert_equal :agent_error, result.status
    assert_equal "first", result.detail
    assert_nil result.reward
  end

  def test_phases_enforce_order
    result = build_result
    result.phase_started(:one)

    assert_raises(ArgumentError) { result.phase_started(:two) }
    assert_raises(ArgumentError) { result.phase_finished(:two) }

    result.phase_finished(:one)

    assert_raises(ArgumentError) { build_result.phase_finished(:one) }
  end

  def test_usage_plus
    source = Lemans::Result::CostSource.new(name: :model_registry, model: "m", priced_as: "m", registry: "r")
    first = Lemans::Result::Usage.new(input_tokens: 100, output_tokens: 10, cached_tokens: 50, steps: 3,
                                      cost_usd: 0.5, cost_source: nil)
    second = Lemans::Result::Usage.new(input_tokens: 200, output_tokens: 20, cached_tokens: 60, steps: 4,
                                       cost_usd: 0.25, cost_source: source)
    total = first + second

    assert_equal 300, total.input_tokens
    assert_equal 30, total.output_tokens
    assert_equal 110, total.cached_tokens
    assert_equal 7, total.steps
    assert_in_delta 0.75, total.cost_usd
    assert_equal source, total.cost_source

    unknown = total + Lemans::Result::Usage.new(input_tokens: 1, output_tokens: 1, cached_tokens: 0, steps: 1,
                                                cost_usd: nil, cost_source: nil)

    assert_nil unknown.cost_usd
    assert_equal source, unknown.cost_source
  end

  def test_step_completed
    result = build_result
    usage = Lemans::Result::Usage.new(input_tokens: 10, output_tokens: 5, cached_tokens: 0, steps: 2,
                                      cost_usd: 0.1, cost_source: nil)
    result.step_completed!(:completed, usage, duration: 3.0)

    assert_equal :completed, result.status
    assert_predicate result, :scored?
    assert_in_delta 0.1, result.usage.cost_usd

    result.step_completed!(:step_limit_reached, usage, duration: 4.0)

    assert_equal 2, result.steps.size
    assert_equal %i[completed step_limit_reached], result.steps.map { it.outcome.status }
    assert_equal [ 3.0, 4.0 ], result.steps.map(&:duration)

    assert_equal :step_limit_reached, result.status
    assert_equal 4, result.usage.steps
    assert_in_delta 0.2, result.usage.cost_usd
  end

  def test_json_round_trip
    result = build_result
    result.phase_started(:agent)
    result.phase_finished(:agent)
    result.completed!(:completed, Lemans::Result::Usage.zero)
    result.graded!(1.0)

    data = JSON.parse(JSON.generate(result.as_json), symbolize_names: true)
    restored = Lemans::Result.from_json(data)

    assert_equal Lemans::VERSION, data[:lemans_version]
    assert_equal result.id, restored.id
    assert_equal 1, restored.index
    assert_equal :completed, restored.status
    assert_predicate restored, :scored?
    assert_in_delta 1.0, restored.reward
    assert_equal %i[agent], restored.phases.map(&:name)
    assert_equal 0, restored.usage.steps
  end

  def test_reads_legacy_result_json
    data = {
      trial: "t__abc1234", task: "t", agent: "oracle", model: "m",
      reward: 1.0, outcome: { name: "completed", scored: true },
      duration_sec: 12.3, bench: { commit: "abc", dirty: false },
      profile_digest: "0" * 16, task_digest: "1" * 16,
      phases: { environment_setup: { started_at: "2026-08-19T00:00:00Z", finished_at: "2026-08-19T00:01:00Z" } }
    }
    result = Lemans::Result.from_json(data)

    assert_equal :completed, result.status
    assert_predicate result, :scored?
    assert_in_delta 12.3, result.duration
    assert_equal "abc", result.revision.commit
    assert_equal %i[environment_setup], result.phases.map(&:name)
  end

  def test_an_unknown_outcome_is_incompatible
    assert_raises(Lemans::Result::IncompatibleError) { Lemans::Result::Outcome.new(:gone_fishing) }
  end
end
