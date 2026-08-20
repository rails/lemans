# frozen_string_literal: true

require "test_helper"
require "csv"

class CLIReportTest < Minitest::Test
  def store_result(store, trial:, task: "hello-world", agent: "miniswen", reward: 1.0,
                   outcome: :completed, detail: nil, cost: 0.0001, tags: [],
                   model: "openrouter/deepseek/deepseek-v4-flash",
                   tokens: { input_tokens: 900, output_tokens: 100 }, duration: 10, steps: 2)
    result = Lemans::Result.new(task:, agent:, model:, id: trial)
    result.tags = tags
    started = Time.utc(2026, 8, 11, 10, trial.length % 10)
    result.phase_started(:agent, started)
    result.phase_finished(:agent, started + duration)

    usage = tokens && Lemans::Result::Usage.new(cached_tokens: 0, steps:, cost_usd: cost, cost_source: nil, **tokens)
    result.completed!(Lemans::Result::Outcome.new(outcome, detail), usage)
    result.graded!(reward) unless reward.nil?
    store.save(result)
    result
  end

  def with_store
    Dir.mktmpdir do |runs_dir|
      store = Lemans::Stores::FS.new(runs_dir)
      store_result(store, trial: "hello-world__aaa", reward: 1.0, tags: %w[infra])
      store_result(store, trial: "hello-world__bbb", reward: nil, outcome: :environment_error,
                          detail: "the daemon is down", cost: nil, tokens: nil)
      store_result(store, trial: "other-task__ccc", task: "other-task", reward: 0.0)
      yield store
    end
  end

  def test_the_rows_show_every_trial_and_the_summary_owns_up_to_the_totals
    with_store do |store|
      report = Lemans::CLI::Report.load(store)
      rows = report.to_rows

      assert_equal %w[task agent model reward outcome cost_usd steps tokens duration trial], rows.first
      assert_includes rows.flatten, "hello-world__aaa"

      solved = rows.find { it.include?("hello-world__aaa") }

      # Tokens sum input and output, leaving cache reads out.
      assert_equal "1000", solved[rows.first.index("tokens")]

      invalid = rows.find { it.include?("hello-world__bbb") }

      assert_includes invalid, "environment_error"
      # A missing reward reads as absent, not as zero.
      assert_equal "-", invalid[rows.first.index("reward")]
      assert_equal "-", invalid[rows.first.index("tokens")]
      assert_includes report.summary_lines.join("\n"), "3 trials: 2 scored, 1 invalid, 1 solved (50%)"
    end
  end

  def test_filters_go_through_the_store_query
    with_store do |store|
      by_name = Lemans::CLI::Report.load(store, names: %w[other-task])
      by_tag = Lemans::CLI::Report.load(store, tags: %w[infra])

      assert_equal(%w[other-task__ccc], by_name.rows.map { it[:trial] })
      assert_equal(%w[hello-world__aaa], by_tag.rows.map { it[:trial] })
      assert_predicate Lemans::CLI::Report.load(store, tags: %w[nope]), :empty?
    end
  end

  def test_a_sweep_groups_the_summary_per_model_with_short_names
    Dir.mktmpdir do |runs_dir|
      store = Lemans::Stores::FS.new(runs_dir)
      store_result(store, trial: "a__1", model: "openrouter/openai/gpt-5.6-luna", reward: 1.0)
      store_result(store, trial: "a__2", model: "openrouter/openai/gpt-5.6-luna", reward: 0.0)
      store_result(store, trial: "a__3", model: "openrouter/z-ai/glm-5.2", reward: 1.0)

      report = Lemans::CLI::Report.load(store)
      lines = report.summary_lines

      assert_equal 3, lines.size
      assert(lines[0..1].any? { it.start_with?("gpt-5.6-luna") && it.include?("1 solved (50%)") })
      assert(lines[0..1].any? { it.start_with?("glm-5.2") && it.include?("1 solved (100%)") })
      assert lines.last.start_with?("total")
      assert_includes lines.last, "2 solved (67%)"
      # The table shows the short name; the CSV keeps the full provenance.
      assert_includes report.to_rows.flatten, "gpt-5.6-luna"
      assert_includes report.to_csv, "openrouter/openai/gpt-5.6-luna"
    end
  end

  def test_the_csv_round_trips_through_a_csv_parser
    with_store do |store|
      parsed = CSV.parse(Lemans::CLI::Report.load(store).to_csv, headers: true)

      assert_equal 3, parsed.size
      assert_equal "the daemon is down", parsed.find { it["trial"] == "hello-world__bbb" }["detail"]
      assert_nil parsed.find { it["trial"] == "hello-world__bbb" }["reward"]
      assert_equal "1.0", parsed.find { it["trial"] == "hello-world__aaa" }["reward"]
    end
  end

  def test_the_flat_report_sorts_numbers_descending_with_missing_values_last
    rows = [
      { task: "a-task", cost_usd: 0.01 },
      { task: "b-task", cost_usd: nil },
      { task: "c-task", cost_usd: 0.05 }
    ]
    report = Lemans::CLI::Report.new(rows)
    tasks = report.order_by!("cost_usd").to_rows.drop(1).map(&:first)

    assert_equal %w[c-task a-task b-task], tasks
    assert_raises(Lemans::ConfigError) { report.order_by!("nope") }
  end

  def test_an_empty_store_is_empty
    Dir.mktmpdir do |runs_dir|
      assert_predicate Lemans::CLI::Report.load(Lemans::Stores::FS.new(runs_dir)), :empty?
    end
  end
end
