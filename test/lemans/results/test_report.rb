# frozen_string_literal: true

require "test_helper"
require "csv"
require "json"
require "tmpdir"

class ReportTest < Minitest::Test
  def write_result(runs_dir, trial:, task: "hello-world", agent: "miniswen", reward: 1.0,
                   outcome: "completed", scored: true, cost: 0.0001, detail: nil)
    result = {
      trial: trial, task: task, agent: agent, model: "openrouter/deepseek/deepseek-v4-flash",
      reward: reward, outcome: { name: outcome, scored: scored, detail: detail }.compact,
      usage: { cost_usd: cost, steps: 2 }, duration_sec: 9.8,
      started_at: "2026-08-11T10:0#{trial.length % 10}:00Z"
    }
    dir = File.join(runs_dir, trial)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "result.json"), JSON.generate(result))
  end

  def with_runs
    Dir.mktmpdir do |runs_dir|
      write_result(runs_dir, trial: "hello-world__aaa", reward: 1.0)
      write_result(runs_dir, trial: "hello-world__bbb", reward: nil, outcome: "environment_error",
                             scored: false, cost: nil, detail: "the daemon is down")
      write_result(runs_dir, trial: "other-task__ccc", task: "other-task", reward: 0.0)
      yield runs_dir
    end
  end

  def test_the_table_shows_every_trial_and_owns_up_to_the_totals
    with_runs do |runs_dir|
      table = Lemans::Results::Report.load(runs_dir).to_table

      assert_includes table, "hello-world__aaa"
      assert_includes table, "environment_error"
      assert_includes table, "3 trials: 2 scored, 1 invalid, 1 solved"
      # A missing reward reads as absent, not as zero.
      assert_match(/-\s+environment_error/, table)
    end
  end

  def test_the_csv_round_trips_through_a_csv_parser
    with_runs do |runs_dir|
      parsed = CSV.parse(Lemans::Results::Report.load(runs_dir).to_csv, headers: true)

      assert_equal 3, parsed.size
      assert_equal "the daemon is down", parsed.find { _1["trial"] == "hello-world__bbb" }["detail"]
      assert_nil parsed.find { _1["trial"] == "hello-world__bbb" }["reward"]
      assert_equal "1.0", parsed.find { _1["trial"] == "hello-world__aaa" }["reward"]
    end
  end

  def test_an_unreadable_result_is_counted_not_dropped_silently
    with_runs do |runs_dir|
      dir = File.join(runs_dir, "hello-world__ddd")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "result.json"), "{ truncated")

      report = Lemans::Results::Report.load(runs_dir)

      assert_equal 3, report.rows.size
      assert_equal 1, report.unreadable
      assert_includes report.to_table, "1 unreadable result(s) skipped"
    end
  end

  def test_an_empty_runs_dir_is_empty
    Dir.mktmpdir do |runs_dir|
      assert_predicate Lemans::Results::Report.load(runs_dir), :empty?
    end
  end
end
