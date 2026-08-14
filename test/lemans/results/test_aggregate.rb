# frozen_string_literal: true

require "test_helper"
require "csv"

class AggregateTest < Minitest::Test
  def build_report(rows)
    Lemans::Results::Report.new(rows: rows.map { row(**_1) })
  end

  def row(task: "hello-world", agent: "miniswen", model: "openrouter/openai/gpt-5.6-luna",
          reward: 1.0, scored: true, cost_usd: 0.01, steps: 4, tokens: 1000, duration_sec: 60.0)
    {
      task: task, agent: agent, model: model, reward: reward, outcome: scored ? "completed" : "environment_error",
      scored: scored, cost_usd: cost_usd, steps: steps, tokens: tokens, duration_sec: duration_sec,
      started_at: "2026-08-11T10:00:00Z", trial: "#{task}__#{rand(1000)}"
    }
  end

  def test_the_keys_spec_reads_dash_joined_columns_and_rejects_anything_else
    assert_equal %i[task model], Lemans::Results::Aggregate.keys("task-model")
    assert_equal %i[task agent model], Lemans::Results::Aggregate.keys("task-agent-model")
    assert_equal %i[model], Lemans::Results::Aggregate.keys("model")

    ["task-reward", "", "task-task", "task-agent-model-task"].each do |spec|
      assert_raises(Lemans::ConfigError) { Lemans::Results::Aggregate.keys(spec) }
    end
  end

  def test_a_group_quotes_solved_over_attempts_median_time_and_mean_spend
    report = build_report([
                            { reward: 1.0, cost_usd: 0.01, steps: 2, tokens: 1000, duration_sec: 10.0 },
                            { reward: 0.0, cost_usd: 0.03, steps: 4, tokens: 3000, duration_sec: 100.0 },
                            { reward: 1.0, cost_usd: nil, steps: nil, tokens: nil, duration_sec: 130.0, scored: false }
                          ])
    aggregate = Lemans::Results::Aggregate.new(report, keys: %i[task model])
    rows = aggregate.to_rows

    assert_equal %w[task model score time cost steps tokens], rows.first
    assert_equal ["hello-world", "gpt-5.6-luna", "2/3", "1m 40s", "$0.02", "3", "2000"], rows.last
  end

  def test_the_aggregate_csv_keeps_raw_values_and_full_model_names
    report = build_report([
                            { reward: 1.0, duration_sec: 10.0 },
                            { reward: 0.0, duration_sec: 20.0 }
                          ])
    parsed = CSV.parse(Lemans::Results::Aggregate.new(report, keys: %i[model]).to_csv, headers: true)

    assert_equal %w[model solved attempts duration_sec cost_usd steps tokens], parsed.headers
    assert_equal "openrouter/openai/gpt-5.6-luna", parsed.first["model"]
    assert_equal "1", parsed.first["solved"]
    assert_equal "2", parsed.first["attempts"]
    assert_equal "15.0", parsed.first["duration_sec"]
  end

  def test_sorting_ranks_scores_best_first_and_key_columns_alphabetically
    report = build_report([
                            { task: "b-task", reward: 0.0 },
                            { task: "b-task", reward: 0.0 },
                            { task: "a-task", reward: 1.0 },
                            { task: "c-task", reward: 1.0 },
                            { task: "c-task", reward: 0.0 }
                          ])
    aggregate = Lemans::Results::Aggregate.new(report, keys: %i[task])

    by_score = aggregate.order_by!(:score).to_rows.drop(1).map(&:first)

    assert_equal %w[a-task c-task b-task], by_score

    by_task = aggregate.order_by!("task").to_rows.drop(1).map(&:first)

    assert_equal %w[a-task b-task c-task], by_task
    assert_raises(Lemans::ConfigError) { aggregate.order_by!("reward") }
  end

  def test_the_flat_report_sorts_numbers_descending_with_missing_values_last
    report = build_report([
                            { task: "a-task", cost_usd: 0.01 },
                            { task: "b-task", cost_usd: nil },
                            { task: "c-task", cost_usd: 0.05 }
                          ])
    tasks = report.order_by!("cost_usd").to_rows.drop(1).map(&:first)

    assert_equal %w[c-task a-task b-task], tasks
    assert_raises(Lemans::ConfigError) { report.order_by!("nope") }
  end
end
