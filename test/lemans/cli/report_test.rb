# frozen_string_literal: true

require "test_helper"
require "csv"

class CLIReportTest < Minitest::Test
  def store_result(store, trial:, task: "hello-world", agent: "miniswen", reward: 1.0, credit: reward,
                   outcome: :completed, detail: nil, cost: 0.0001, tags: [],
                   model: "openrouter/deepseek/deepseek-v4-flash", metadata: {},
                   tokens: { input_tokens: 900, output_tokens: 100 }, duration: 10, steps: 2)
    result = Lemans::Result.new(task:, agent:, model:, id: trial)
    result.tags = tags
    result.metadata = metadata
    started = Time.utc(2026, 8, 11, 10, trial.length % 10)
    result.phase_started(:agent, started)
    result.phase_finished(:agent, started + duration)

    usage = tokens && Lemans::Result::Usage.new(cached_tokens: 0, steps:, cost_usd: cost, cost_source: nil, **tokens)
    result.completed!(Lemans::Result::Outcome.new(outcome, detail), usage)
    result.graded!(reward, credit:) unless reward.nil?
    store.save(result)
    result
  end

  def with_store
    Dir.mktmpdir do |runs_dir|
      store = Lemans::Stores::FS.new(runs_dir)
      store_result(store, trial: "hello-world__aaa", reward: 1.0, tags: %w[infra],
                          metadata: { "category" => "full-features", "app" => "campfire" })
      store_result(store, trial: "hello-world__bbb", reward: nil, outcome: :environment_error,
                          detail: "the daemon is down", cost: nil, tokens: nil)
      store_result(store, trial: "other-task__ccc", task: "other-task", reward: 0.0, credit: 0.4,
                          metadata: { "app" => "campfire" })
      yield store
    end
  end

  def test_the_rows_show_every_trial_and_the_summary_owns_up_to_the_totals
    with_store do |store|
      report = Lemans::CLI::Report.load(store)
      rows = report.to_rows

      assert_equal %w[task agent model reward credit outcome cost_usd steps tokens duration trial], rows.first
      assert_includes rows.flatten, "hello-world__aaa"

      solved = rows.find { it.include?("hello-world__aaa") }

      # Tokens sum input and output, leaving cache reads out.
      assert_equal "1.0K", solved[rows.first.index("tokens")]
      assert_equal "1", solved[rows.first.index("credit")]
      assert_equal "10s", solved[rows.first.index("duration")]
      assert_equal "$0.0001", solved[rows.first.index("cost_usd")]

      partial = rows.find { it.include?("other-task__ccc") }

      assert_equal "0", partial[rows.first.index("reward")]
      assert_equal "0.4", partial[rows.first.index("credit")]

      invalid = rows.find { it.include?("hello-world__bbb") }

      assert_includes invalid, "environment_error"
      # A missing reward reads as absent, not as zero.
      assert_equal "-", invalid[rows.first.index("reward")]
      assert_equal "-", invalid[rows.first.index("credit")]
      assert_equal "-", invalid[rows.first.index("tokens")]
      assert_includes report.summary_lines.join("\n"), "3 trials: 2 scored, 1 invalid, 1 solved (50%)"
    end
  end

  def test_the_credit_column_appears_only_once_a_credit_differs_from_its_reward
    Dir.mktmpdir do |dir|
      store = Lemans::Stores::FS.new(dir)
      store_result(store, trial: "hello-world__aaa", reward: 1.0)
      store_result(store, trial: "hello-world__bbb", reward: nil, outcome: :environment_error, cost: nil, tokens: nil)
      report = Lemans::CLI::Report.load(store)

      refute_includes report.to_rows.first, "credit"
      refute_includes Lemans::CLI::Report::Aggregate.new(report, keys: %i[task]).to_rows.first, "credit"
      assert_includes report.to_csv.lines.first, "credit"
    end
  end

  def test_filters_go_through_the_store_query
    with_store do |store|
      by_name = Lemans::CLI::Report.load(store, names: %w[other-task])
      by_tag = Lemans::CLI::Report.load(store, tags: %w[infra])

      assert_equal(%w[other-task__ccc], by_name.rows.map { it[:trial] })
      assert_equal(%w[hello-world__aaa], by_tag.rows.map { it[:trial] })
      assert_predicate Lemans::CLI::Report.load(store, tags: %w[nope]), :empty?

      by_metadata = Lemans::CLI::Report.load(store, metadata: { "app" => "campfire", "category" => "full-features" })
      by_app = Lemans::CLI::Report.load(store, metadata: { "app" => "campfire" })

      assert_equal(%w[hello-world__aaa], by_metadata.rows.map { it[:trial] })
      assert_equal(%w[hello-world__aaa other-task__ccc], by_app.rows.map { it[:trial] })
    end
  end

  def test_the_metadata_filter_reads_key_value_pairs
    assert_nil Lemans::CLI::Report.metadata_filter(nil)
    assert_nil Lemans::CLI::Report.metadata_filter([])
    assert_equal({ "category" => "full-features", "app" => "campfire:v2" },
                 Lemans::CLI::Report.metadata_filter(%w[category:full-features app:campfire:v2]))

    [ "category", ":full-features" ].each do |spec|
      error = assert_raises(Lemans::ConfigError) { Lemans::CLI::Report.metadata_filter([ spec ]) }

      assert_includes error.message, "expected key:value"
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
      assert_equal "0.4", parsed.find { it["trial"] == "other-task__ccc" }["credit"]
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
    assert_raises(Lemans::ConfigError) { report.order_by!("cost_usd-nope") }
    assert_raises(Lemans::ConfigError) { report.order_by!("") }
  end

  def test_the_flat_report_sorts_by_several_columns
    rows = [
      { task: "a-task", trial: "1", reward: 1.0, cost_usd: 0.01, features: { "auto-join" => true } },
      { task: "b-task", trial: "2", reward: 1.0, cost_usd: 0.05, features: { "auto-join" => false } },
      { task: "a-task", trial: "3", reward: 0.0, cost_usd: 0.02, features: { "auto-join" => true } },
      { task: "b-task", trial: "4", reward: nil, cost_usd: 0.03, features: nil }
    ]
    report = Lemans::CLI::Report.new(rows)
    trials = ->(spec) { report.order_by!(spec).rows.map { it[:trial] } }

    assert_equal %w[2 1 3 4], trials.("reward-cost_usd")
    assert_equal %w[1 2 3 4], trials.("reward-^cost_usd")
    assert_equal %w[3 2 1 4], trials.("^reward-cost_usd")
    assert_equal %w[3 1 2 4], trials.("task-^reward")
    assert_equal %w[2 4 1 3], trials.("^task-reward")
    assert_equal %w[1 3 2 4], trials.("feat:auto-join-^cost_usd")
  end

  def test_the_progress_column_appears_only_for_multistep_trials
    with_store do |store|
      report = Lemans::CLI::Report.load(store)

      refute_includes report.to_rows.first, "progress"

      rows = report.rows + [
        { task: "ms-task", trial: "ms-task__a", completed_steps: 2, total_steps: 5 },
        { task: "ms-task", trial: "ms-task__b", completed_steps: 5, total_steps: 5 },
        { task: "ms-task", trial: "ms-task__c", completed_steps: 1, total_steps: nil }
      ]
      report = Lemans::CLI::Report.new(rows).order_by!("progress")
      table = report.to_rows
      column = table.first.index("progress")

      assert_equal %w[5/5 2/5 1/5 - - -], table.drop(1).map { it[column] }

      other = Lemans::CLI::Report.new([ { task: "ms-other", trial: "ms-other__a", completed_steps: 1 } ])

      assert_nil other.rows.first[:total_steps]

      solved = Lemans::CLI::Report.new([ { task: "ms-other", trial: "ms-other__a", completed_steps: 1 },
                                         { task: "ms-other", trial: "ms-other__b", completed_steps: 4, reward: 1.0 } ])

      assert_equal [ 4, 4 ], solved.rows.map { it[:total_steps] }
      assert_includes report.to_csv.lines.first, "completed_steps,total_steps"
    end
  end

  def test_feature_columns_show_the_features_every_task_tracks
    rows = [
      { task: "a-task", trial: "a-task__a", features: { "migrations" => true, "archspec" => false } },
      { task: "a-task", trial: "a-task__b", features: { "migrations" => false, "archspec" => true } },
      { task: "a-task", trial: "a-task__c", features: nil },
      { task: "b-task", trial: "b-task__a", features: { "migrations" => true, "ssrf" => true } },
      { task: "c-task", trial: "c-task__a", features: nil }
    ]
    default = Lemans::CLI::Report.new(rows).order_by!("features")
    table = default.to_rows
    column = table.first.index("features")

    refute_includes table.first, "feat:migrations"
    assert_equal %w[2/2 1/2 1/2 - -], table.drop(1).map { it[column] }
    refute_includes default.to_csv.lines.first, "feat:migrations"
    assert_equal %w[2 1 1] + [ nil, nil ], CSV.parse(default.to_csv, headers: true).map { it["features_passed"] }
    refute_includes Lemans::CLI::Report.new(rows.last(1)).to_rows.first, "features"

    report = Lemans::CLI::Report.new(rows, show_features: true).order_by!("feat:migrations")
    table = report.to_rows
    column = table.first.index("feat:migrations")

    assert_equal %w[feat:migrations trial], table.first.last(2)
    assert_equal %w[✓ ✓ ✗ - -], table.drop(1).map { it[column] }
    assert_equal %i[feat:archspec feat:migrations], Lemans::CLI::Report.new(rows.first(3)).feature_columns
    assert_empty Lemans::CLI::Report.new(rows.last(1)).feature_columns

    csv = CSV.parse(report.to_csv, headers: true)

    assert_equal %w[true true false] + [ nil, nil ], csv.map { it["feat:migrations"] }
    assert_raises(Lemans::ConfigError) { report.order_by!("feat:ssrf") }
  end

  def test_display_formats
    report = Lemans::CLI::Report

    assert_equal [ "-", "999", "1.5K", "6.1M", "1.2B" ], [ nil, 999, 1500, 6_058_463, 1.2e9 ].map { report.tokens_display(it) }
    assert_equal [ "-", "45s", "77m 26s" ], [ nil, 45.2, 4646.4 ].map { report.duration_display(it) }
    assert_equal [ "-", "$2.7598", "$13" ], [ nil, 2.759812, 13.0 ].map { report.cost_display(it) }
  end

  def test_hide_columns_leaves_known_columns_out_and_lets_the_rest_go
    rows = [ { task: "a-task", trial: "a-task__a", reward: 1.0, features: { "auto-join" => true } } ]
    report = Lemans::CLI::Report.new(rows, show_features: true, hide_columns: "steps-tokens-nope-feat:auto-join--trial-^")

    assert_equal %w[task agent model reward features outcome cost_usd duration], report.to_rows.first
    assert_includes report.to_csv.lines.first, "tokens"
    assert_includes Lemans::CLI::Report.new(rows, hide_columns: "").to_rows.first, "trial"
  end

  def test_skip_invalid_leaves_invalid_trials_out
    with_store do |store|
      report = Lemans::CLI::Report.load(store, skip_invalid: true)

      assert_equal %w[hello-world__aaa other-task__ccc], report.rows.map { it[:trial] }
      assert_equal 0, report.summary[:invalid]
    end
  end

  def test_an_empty_store_is_empty
    Dir.mktmpdir do |runs_dir|
      assert_predicate Lemans::CLI::Report.load(Lemans::Stores::FS.new(runs_dir)), :empty?
    end
  end

  def test_unreadable_results_are_skipped_but_said_out_loud
    with_store do |store|
      truncated = store.send(:root).join("model-a", "broken__abc1234")
      truncated.mkpath
      truncated.join("result.json").write("{ half a resu")

      report = Lemans::CLI::Report.load(store)

      assert_equal 3, report.rows.size
      assert_includes report.summary_lines.last, "1 unreadable result(s) skipped"
    end
  end

  def test_a_store_holding_only_unreadable_results_is_not_empty
    Dir.mktmpdir do |runs_dir|
      store = Lemans::Stores::FS.new(runs_dir)
      broken = Pathname(runs_dir).join("model-a", "broken__abc1234")
      broken.mkpath
      broken.join("result.json").write("{ half a resu")

      report = Lemans::CLI::Report.load(store)

      refute_predicate report, :empty?
      assert_equal [ "0 trials: 0 scored, 0 invalid, 0 solved · $0.0000 · 1 unreadable result(s) skipped" ],
                   report.summary_lines
    end
  end
end
