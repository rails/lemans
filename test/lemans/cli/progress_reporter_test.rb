# frozen_string_literal: true

require "test_helper"

class ProgressReporterTest < Minitest::Test
  def build_reporter
    Lemans::CLI::ProgressReporter.new(shell: Thor::Shell::Basic.new, tasks: %w[hello-world])
  end

  def result(status: :completed, reward: 1.0, detail: nil)
    Lemans::Runner::Result.new(task: "hello-world", model: "m/model-a", index: 1, status:, reward:, duration: 42, detail:)
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
    assert_includes out, "42s"
    assert_includes out, "abandoning in-flight"
  end

  def test_invalid_result_gets_a_short_verb_and_the_detail
    out, = capture_io { build_reporter.record(:finished, result(status: :verifier_error, reward: nil, detail: "no reward file")) }

    assert_includes out, "invalid"
    assert_includes out, "verifier_error"
    assert_includes out, "no reward file"
  end
end
