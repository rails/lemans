# frozen_string_literal: true

require "test_helper"
require "stringio"

class BoardReporterTest < Minitest::Test
  def build_reporter(out, attempts: 1)
    Lemans::CLI::BoardReporter.new(tasks: %w[hello-world], models: %w[m/model-a], attempts:, out:)
  end

  def runner_task(index: 1)
    Lemans::Runner::Task.new("m/model-a", Lemans::TaskDefinition.new(Lemans::Config.new, "hello-world"), index:)
  end

  def result(status: :completed, reward: 1.0, detail: nil)
    raw = Lemans::Trial::Result.new(agent: "oracle", model: "m/model-a")
    raw.status = status
    raw.reward = reward
    raw.detail = detail
    Lemans::Runner::Result.new(task: "hello-world", model: "m/model-a", index: 1, id: "hello-world__abc1234", raw:)
  end

  def test_draws_the_final_board
    out = StringIO.new
    reporter = build_reporter(out).start
    reporter.record(:started, runner_task)
    reporter.record(:finished, result)
    reporter.stop

    assert_includes out.string, "hello-world"
    assert_includes out.string, "model-a"
    assert_includes out.string, "✔"
    assert_includes out.string, "1/1 done"
  end

  def test_announces_invalid_results
    out = StringIO.new
    build_reporter(out).record(:finished, result(status: :agent_error, reward: nil, detail: "sandbox died\nmore"))

    assert_includes out.string, "sandbox died"
    refute_includes out.string, "more"
  end

  def test_interrupt_message
    out = StringIO.new
    reporter = build_reporter(out)
    reporter.record(:started, runner_task)
    reporter.record(:interrupted)

    assert_includes out.string, "abandoning 1 in-flight"
  end
end
