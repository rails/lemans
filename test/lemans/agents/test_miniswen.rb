# frozen_string_literal: true

require "test_helper"
require "tmpdir"

require_relative "../../miniswen/agent_test"

class MiniswenAdapterTest < Minitest::Test
  include BenchFixture

  SUBMIT = MiniswenAgentTest::SUBMIT

  def answer(*commands, content: "Let me try.")
    { content: content, tool_calls: commands.map { { name: "bash", arguments: { "command" => _1 } } } }
  end

  def build_agent(responses, cost_usd: 0.01, thinking: nil)
    bench = load_bench
    agent = Lemans::Agents::Base.build("miniswen", profile: bench.agent)
    llm = MiniswenAgentTest::ScriptedLLM.new(responses, cost_usd: cost_usd, thinking: thinking)
    agent.define_singleton_method(:loop_for) { |env| MiniswenAgentTest::ScriptedLoop.new(llm: llm, environment: env) }
    [agent, load_task(bench)]
  end

  def call(agent, task)
    Dir.mktmpdir do |dir|
      logs_dir = Pathname(dir)
      result = agent.call(MiniswenAgentTest::ScriptedShell.new, task: task, logs_dir: logs_dir)
      trajectory = JSON.parse(logs_dir.join("miniswen.trajectory.json").read)
      return [result, trajectory]
    end
  end

  def test_a_submission_is_a_completed_scored_trial_with_priced_usage
    agent, task = build_agent([answer("echo hello > /app/hello.txt", content: "I made the file."), SUBMIT])
    result, trajectory = call(agent, task)

    assert_predicate result.outcome, :completed?
    assert_predicate result.outcome, :scored?
    assert_in_delta 0.02, result.usage.cost_usd
    assert_equal 2, result.usage.steps
    assert_equal :agent, result.usage.cost_source.name

    assert_equal "ATIF-v1.7", trajectory["schema_version"]
    assert_equal "submitted", trajectory.dig("extra", "status")
    # The task's real instruction reached the model.
    assert(trajectory["steps"].any? { _1["message"].include?("hello.txt") })
  end

  def test_the_trajectory_is_native_atif_with_linked_calls_and_metrics
    agent, task = build_agent([answer("date", content: "Checking the date."), SUBMIT])
    _result, trajectory = call(agent, task)

    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")

    agent_step = trajectory["steps"].find { _1["source"] == "agent" }
    call_id = agent_step.dig("tool_calls", 0, "tool_call_id")

    assert_equal "bash", agent_step.dig("tool_calls", 0, "function_name")
    assert_equal "date", agent_step.dig("tool_calls", 0, "arguments", "command")
    assert_equal 100, agent_step.dig("metrics", "prompt_tokens")

    observation_step = trajectory["steps"].find { _1["observation"] }

    assert_equal call_id, observation_step.dig("observation", "results", 0, "source_call_id")
    assert_equal 200, trajectory.dig("final_metrics", "total_prompt_tokens")
    assert_equal "miniswen", trajectory.dig("agent", "name")
  end

  def test_thinking_travels_into_the_trajectory
    agent, task = build_agent([answer("date", content: "Checking."), SUBMIT], thinking: "the task wants a date")
    _result, trajectory = call(agent, task)

    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")

    agent_step = trajectory["steps"].find { _1["source"] == "agent" }

    assert_equal "the task wants a date", agent_step["reasoning_content"]
    assert_equal 1, agent_step["llm_call_count"]
    assert_equal 40, agent_step.dig("metrics", "extra", "reasoning_tokens")
    assert_equal 80, trajectory.dig("final_metrics", "extra", "total_reasoning_tokens")
  end

  def test_a_model_that_cannot_format_is_still_scored
    agent, task = build_agent([{ content: "no call" }, { content: "still none" }, { content: "never" }])
    result, trajectory = call(agent, task)

    assert_predicate result.outcome, :completed?
    assert_equal "three consecutive responses without a valid bash tool call", result.outcome.detail
    assert_equal "format_error", trajectory.dig("extra", "status")
    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")
  end

  def test_tokens_billed_at_an_unknown_rate_are_refused_not_free
    agent, task = build_agent([SUBMIT], cost_usd: nil)

    assert_raises(Miniswen::AccountingError) { call(agent, task) }
  end

  def test_the_profile_config_reaches_the_loop_mini_style
    bench = load_bench
    agent = Lemans::Agents::Base.build("miniswen", profile: bench.agent)
    loop_config = agent.send(:loop_for, MiniswenAgentTest::ScriptedShell.new)

    assert_equal 100, loop_config.instance_variable_get(:@max_steps)
    assert_equal 300, loop_config.instance_variable_get(:@exec_timeout)
    assert_in_delta 5.0, loop_config.instance_variable_get(:@max_cost)
  end
end
