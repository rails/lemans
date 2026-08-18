# frozen_string_literal: true

require "test_helper"
require "tmpdir"

require "miniswen/testing"

class MiniswenInstalledTest < Minitest::Test
  include BenchFixture
  include Miniswen::Testing

  def build_agent
    bench = load_bench
    [Lemans::Agents.build("miniswen-installed", profile: bench.agent), load_task(bench)]
  end

  # The fixture model resolves through openrouter; pinning its key keeps the
  # tests independent of whatever the developer's shell exports.
  def with_openrouter_key(value = "test-key")
    original = RubyLLM.config.openrouter_api_key
    RubyLLM.configure { _1.openrouter_api_key = value }
    yield
  ensure
    RubyLLM.configure { _1.openrouter_api_key = original }
  end

  # A genuine remote payload: what the sandboxed CLI would leave behind
  # after a scripted run.
  def remote_result_json
    stub_llm(SUBMIT)
    loop_agent = Miniswen::Agent.new(model: "test", environment: FakeEnv.new)
    JSON.generate(loop_agent.run("task").to_h)
  end

  def test_install_puts_the_pinned_gem_and_refreshes_the_registry_while_the_network_is_open
    agent, task = build_agent
    shell = FakeEnvironment.new

    agent.install(shell, task: task)

    assert_equal [
      "command -v miniswen >/dev/null 2>&1 || gem install miniswen -v #{Miniswen::VERSION} --no-document",
      "miniswen --refresh-registry"
    ], shell.commands
  end

  def test_a_remote_run_is_downloaded_and_reported_through_the_shared_atif_tail
    agent, task = build_agent
    shell = FakeEnvironment.new(files: { Lemans::Agents::MiniswenInstalled::RESULTS_PATH => remote_result_json })

    Dir.mktmpdir do |dir|
      logs_dir = Pathname(dir)
      result = with_openrouter_key { agent.call(shell, task: task, logs_dir: logs_dir) }

      assert_predicate result.outcome, :completed?
      assert_predicate result.outcome, :scored?
      assert_in_delta 0.01, result.usage.cost_usd
      assert_equal :model_registry, result.usage.cost_source.name

      command = shell.commands.last

      assert_includes command, "miniswen -q --no-refresh-registry"
      assert_includes command, "-m openrouter/z-ai/glm-5.2"
      assert_includes command, "--results-path /tmp/lemans-miniswen.result.json"
      assert_includes command, "--max-steps 100"
      assert_includes command, "--max-cost 5"

      trajectory = JSON.parse(logs_dir.join("trajectory.json").read)

      assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")
      assert_equal "submitted", trajectory.dig("extra", "status")
      assert_equal "miniswen-installed", trajectory.dig("agent", "name")
      # The raw remote result stays behind as a log artifact.
      assert_predicate logs_dir.join("miniswen.result.json"), :file?
    end
  end

  def test_a_missing_result_file_is_an_infrastructure_failure_with_the_runs_output
    agent, task = build_agent
    shell = FakeEnvironment.new

    Dir.mktmpdir do |dir|
      error = assert_raises(Lemans::InfrastructureError) do
        with_openrouter_key { agent.call(shell, task: task, logs_dir: Pathname(dir)) }
      end

      assert_match(/no usable result file/, error.message)
    end
  end

  def test_a_missing_provider_credential_aborts_before_the_sandbox_runs_anything
    agent, task = build_agent
    shell = FakeEnvironment.new

    Dir.mktmpdir do |dir|
      error = assert_raises(Lemans::ConfigError) do
        with_openrouter_key(nil) { agent.call(shell, task: task, logs_dir: Pathname(dir)) }
      end

      assert_match(/openrouter_api_key/, error.message)
      assert_empty shell.commands
    end
  end
end
