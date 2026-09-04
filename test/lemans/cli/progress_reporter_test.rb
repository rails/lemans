# frozen_string_literal: true

require "test_helper"

class ProgressReporterTest < Minitest::Test
  def build_reporter
    Lemans::CLI::ProgressReporter.new(shell: Thor::Shell::Basic.new, tasks: %w[hello-world])
  end

  def result(status: :completed, reward: 1.0, credit: reward, detail: nil)
    result = Lemans::Result.new(task: "hello-world", agent: "oracle", model: "m/model-a", index: 1)
    result.phase_started(:agent, Time.at(0).utc)
    result.phase_finished(:agent, Time.at(42).utc)
    result.completed!(Lemans::Result::Outcome.new(status, detail)).graded!(reward, credit:)
  end

  def test_one_line_per_event
    task = Lemans::Runner::Task.new("m/model-a", Lemans::TaskDefinition.new(Lemans::Config.new, "hello-world"), index: 1)
    reporter = build_reporter

    out, = capture_io do
      reporter.record(:started, task)
      reporter.record(:finished, result)
      reporter.record(:interrupted)
    end

    assert_includes out, "attempt 1/1"
    assert_includes out, task.id
    assert_includes out, "reward=1.0"
    refute_includes out, "credit="
    assert_includes out, "42.0s"
    assert_includes out, "abandoning in-flight"
  end

  def test_a_fractional_credit_shows_next_to_the_reward
    out, = capture_io { build_reporter.record(:finished, result(reward: 0.0, credit: 0.7)) }

    assert_includes out, "reward=0.0 credit=0.7"
  end

  def test_invalid_result_gets_a_short_verb_and_the_detail
    out, = capture_io { build_reporter.record(:finished, result(status: :verifier_error, reward: nil, detail: "no reward file")) }

    assert_includes out, "invalid"
    assert_includes out, "verifier_error"
    assert_includes out, "no reward file"
  end
end
