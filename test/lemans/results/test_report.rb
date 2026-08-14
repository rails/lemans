# frozen_string_literal: true

require "test_helper"
require "csv"
require "json"
require "tmpdir"

class ReportTest < Minitest::Test
  def write_result(runs_dir, trial:, task: "hello-world", agent: "miniswen", reward: 1.0,
                   outcome: "completed", scored: true, cost: 0.0001, detail: nil,
                   model: "openrouter/deepseek/deepseek-v4-flash", tokens: { input_tokens: 900, output_tokens: 100 },
                   duration: 9.8, steps: 2)
    result = {
      trial: trial, task: task, agent: agent, model: model,
      reward: reward, outcome: { name: outcome, scored: scored, detail: detail }.compact,
      usage: { cost_usd: cost, steps: steps }.merge(tokens || {}), duration_sec: duration,
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
                             scored: false, cost: nil, detail: "the daemon is down", tokens: nil)
      write_result(runs_dir, trial: "other-task__ccc", task: "other-task", reward: 0.0)
      yield runs_dir
    end
  end

  def test_the_rows_show_every_trial_and_the_summary_owns_up_to_the_totals
    with_runs do |runs_dir|
      report = Lemans::Results::Report.load(runs_dir)
      rows = report.to_rows

      assert_equal %w[task agent model reward outcome cost_usd steps tokens duration_sec trial], rows.first
      assert_includes rows.flatten, "hello-world__aaa"

      solved = rows.find { _1.include?("hello-world__aaa") }

      # Tokens sum input and output, leaving cache reads out.
      assert_equal "1000", solved[rows.first.index("tokens")]

      invalid = rows.find { _1.include?("hello-world__bbb") }

      assert_includes invalid, "environment_error"
      # A missing reward reads as absent, not as zero.
      assert_equal "-", invalid[rows.first.index("reward")]
      assert_equal "-", invalid[rows.first.index("tokens")]
      assert_includes report.summary_lines.join("\n"), "3 trials: 2 scored, 1 invalid, 1 solved (50%)"
    end
  end

  def test_a_sweep_groups_the_summary_per_model_with_short_names
    Dir.mktmpdir do |runs_dir|
      write_result(runs_dir, trial: "a__1", model: "openrouter/openai/gpt-5.6-luna", reward: 1.0)
      write_result(runs_dir, trial: "a__2", model: "openrouter/openai/gpt-5.6-luna", reward: 0.0)
      write_result(runs_dir, trial: "a__3", model: "openrouter/z-ai/glm-5.2", reward: 1.0)

      report = Lemans::Results::Report.load(runs_dir)
      lines = report.summary_lines

      assert_equal 3, lines.size
      assert(lines[0..1].any? { _1.start_with?("gpt-5.6-luna") && _1.include?("1 solved (50%)") })
      assert(lines[0..1].any? { _1.start_with?("glm-5.2") && _1.include?("1 solved (100%)") })
      assert lines.last.start_with?("total")
      assert_includes lines.last, "2 solved (67%)"
      # The table shows the short name; the CSV keeps the full provenance.
      assert_includes report.to_rows.flatten, "gpt-5.6-luna"
      assert_includes report.to_csv, "openrouter/openai/gpt-5.6-luna"
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
      assert_includes report.summary_lines.join("\n"), "1 unreadable result(s) skipped"
    end
  end

  def test_an_empty_runs_dir_is_empty
    Dir.mktmpdir do |runs_dir|
      assert_predicate Lemans::Results::Report.load(runs_dir), :empty?
    end
  end
end
