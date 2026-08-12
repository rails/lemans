# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "yaml"

class RunTest < Minitest::Test
  include CorpusFixture

  def build_run(runs_dir, **)
    bench = load_bench
    Lemans::Run.new(bench: bench, tasks: [load_task(bench)], agent_name: "oracle",
                    runs_dir: runs_dir, backend: "daytona", concurrency: 1, **)
  end

  def retire(runs_dir, scored:, agent: "oracle", profile_digest: nil, task_digest: nil)
    bench = load_bench
    dir = File.join(runs_dir, "hello-world__#{scored ? "done" : "bad"}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "result.json"), JSON.generate(
                                                task: "hello-world", agent: agent, model: "openrouter/z-ai/glm-5.2",
                                                profile_digest: profile_digest || bench.digest,
                                                task_digest: task_digest || load_task(bench).digest,
                                                outcome: { name: "completed", scored: scored }
                                              ))
  end

  def test_resume_skips_attempts_a_scored_result_already_retired
    Dir.mktmpdir do |runs_dir|
      retire(runs_dir, scored: true)

      summary = build_run(runs_dir, resume: true, attempts: 1).call

      assert_equal 0, summary[:total]
    end
  end

  # Every result records what it measured; resume must consult it, or editing
  # bench.yml and resuming lets old-profile trials satisfy the new wave.
  def test_resume_does_not_count_a_trial_from_another_profile_or_task_version
    Dir.mktmpdir do |runs_dir|
      retire(runs_dir, scored: true, profile_digest: "0ld-pr0f1le-d1gest")

      fake = FakeEnvironment.new(on_command: lambda { |files|
        files["/logs/verifier/reward.txt"] = "1"
        files["/logs/verifier/checks.txt"] = "ran"
      })
      summary = Lemans::Environments.stub(:build, ->(*, **) { fake }) do
        build_run(runs_dir, resume: true, attempts: 1).call
      end

      assert_equal 1, summary[:total]
    end
  end

  def test_resume_does_not_count_an_invalid_trial_or_another_agents_pass
    Dir.mktmpdir do |runs_dir|
      retire(runs_dir, scored: false)
      retire(runs_dir, scored: true, agent: "nop")

      fake = FakeEnvironment.new(on_command: lambda { |files|
        files["/logs/verifier/reward.txt"] = "1"
        files["/logs/verifier/checks.txt"] = "ran"
      })
      summary = Lemans::Environments.stub(:build, ->(*, **) { fake }) do
        build_run(runs_dir, resume: true, attempts: 1).call
      end

      assert_equal({ total: 1, scored: 1, invalid: 0, solved: 1 }, summary)
    end
  end

  def test_a_model_list_runs_the_whole_grid_once_per_model
    Dir.mktmpdir do |runs_dir|
      config = YAML.safe_load_file(CorpusFixture::ROOT.join("bench.yml"), aliases: true)
      config["agent"]["model"] = %w[model-a model-b]
      bench = Lemans::Corpus::Bench.new(config, path: CorpusFixture::ROOT.join("bench.yml"))
      run = Lemans::Run.new(bench: bench, tasks: [bench.tasks.fetch(0)], agent_name: "oracle",
                            runs_dir: runs_dir, backend: "daytona", concurrency: 1)

      fakes = Array.new(2) do
        FakeEnvironment.new(on_command: lambda { |files|
          files["/logs/verifier/reward.txt"] = "1"
          files["/logs/verifier/checks.txt"] = "ran"
        })
      end
      summary = Lemans::Environments.stub(:build, ->(*, **) { fakes.shift }) { run.call }

      assert_equal 2, summary[:total]

      models = Pathname(runs_dir).glob("*/result.json").map { JSON.parse(_1.read)["model"] }

      assert_equal %w[model-a model-b], models.sort
    end
  end

  def test_a_crashed_trial_becomes_a_visible_invalid_result_not_a_silent_hole
    Dir.mktmpdir do |runs_dir|
      lines = []
      exploding = ->(*, **) { raise "the harness tripped over itself" }
      summary = Lemans::Environments.stub(:build, exploding) do
        build_run(runs_dir, attempts: 1).call { lines << _1 }
      end

      assert_equal({ total: 1, scored: 0, invalid: 1, solved: 0 }, summary)
      assert(lines.any? { _1.include?("harness_crash") })
      # The crash is on disk where `lemans report` can see it.
      outcomes = Pathname(runs_dir).glob("*/result.json").map { JSON.parse(_1.read).dig("outcome", "name") }

      assert_equal ["harness_crash"], outcomes
    end
  end

  def test_a_config_error_aborts_the_wave_instead_of_burning_the_grid
    Dir.mktmpdir do |runs_dir|
      bench = load_bench
      run = Lemans::Run.new(bench: bench, tasks: [load_task(bench)], agent_name: "bogus",
                            runs_dir: runs_dir, backend: "daytona", concurrency: 1, attempts: 3)

      assert_raises(Lemans::ConfigError) do
        Lemans::Environments.stub(:build, ->(*, **) { FakeEnvironment.new }) { run.call }
      end

      # Nothing was recorded: the author's bug is not a measurement.
      assert_empty Pathname(runs_dir).glob("*/result.json")
    end
  end
end
