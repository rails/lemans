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
    # Duration derives from the recorded phases, not the legacy duration_sec.
    assert_in_delta 60.0, result.duration
    assert_equal "abc", result.revision.commit
    assert_equal %i[environment_setup], result.phases.map(&:name)
  end

  def test_an_unknown_outcome_is_incompatible
    assert_raises(Lemans::Result::IncompatibleError) { Lemans::Result::Outcome.new(:gone_fishing) }
  end
end
