# frozen_string_literal: true

require "test_helper"

require "miniswen"
require "miniswen/testing"

class MiniswenTrajectoryTest < Minitest::Test
  include Miniswen::Testing

  def setup
    @fake_env = FakeEnv.new
    build_agent
  end

  def trajectory_for(result, **)
    Miniswen::Trajectory.from(result, model: "test", **).to_atif
  end

  def as_json(document) = JSON.parse(JSON.generate(document))

  def test_a_run_serializes_as_conformant_atif
    stub_llm("ls /app", SUBMIT)
    fake_env.on("ls /app", "hello.txt")
    result = agent.run("List the app directory.")

    trajectory = as_json(trajectory_for(result, session_id: "hello-world__abc1234"))

    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")
    assert_equal "ATIF-v1.7", trajectory["schema_version"]
    assert_equal "hello-world__abc1234", trajectory["session_id"]
    assert_equal "miniswen", trajectory.dig("agent", "name")
    assert_equal Miniswen::VERSION, trajectory.dig("agent", "version")
    assert_equal "test", trajectory.dig("agent", "model_name")
    assert_equal "submitted", trajectory.dig("extra", "status")
  end

  def test_tool_results_fold_into_the_step_that_called_them
    stub_llm("ls /app", SUBMIT)
    fake_env.on("ls /app", "hello.txt")
    result = agent.run("List the app directory.")

    trajectory = as_json(trajectory_for(result))
    steps = trajectory["steps"]

    # No step comes from a tool: observations ride the agent turn that asked.
    assert_equal(%w[system user agent agent], steps.map { _1["source"] })
    assert_equal((1..steps.size).to_a, steps.map { _1["step_id"] })

    called = steps.find { _1["observation"] }

    assert_equal "agent", called["source"]
    call_id = called.dig("tool_calls", 0, "tool_call_id")

    assert_equal call_id, called.dig("observation", "results", 0, "source_call_id")
    # The content is the envelope the model saw, parseable as the JSON it is.
    envelope = JSON.parse(called.dig("observation", "results", 0, "content"))

    assert_equal 0, envelope["returncode"]
    assert_includes envelope["output"], "hello.txt"
    assert_equal 0, called.dig("observation", "results", 0, "extra", "exit_code")
  end

  def test_model_turns_carry_timestamps_metrics_and_one_llm_call
    stub_llm(SUBMIT)
    result = agent.run("Just submit.")

    trajectory = as_json(trajectory_for(result))
    turn = trajectory["steps"].find { _1["source"] == "agent" }

    assert_match(/\A\d{4}-\d{2}-\d{2}T/, turn["timestamp"])
    assert_equal "test", turn["model_name"]
    assert_equal 1, turn["llm_call_count"]
    assert_equal 100, turn.dig("metrics", "prompt_tokens")
    # Cached tokens nest where the provider payload puts them.
    assert_equal 5, turn.dig("metrics", "extra", "prompt_tokens_details", "cached_tokens")
    # total_steps counts model turns, and the steps array now agrees.
    agent_steps = trajectory["steps"].count { _1["source"] == "agent" }

    assert_equal trajectory.dig("final_metrics", "total_steps"), agent_steps
  end

  def test_thinking_nests_as_reasoning_details
    stub_llm(SUBMIT, thinking: "just do it")
    result = agent.run("Just submit.")

    trajectory = as_json(trajectory_for(result))
    turn = trajectory["steps"].find { _1["source"] == "agent" }

    assert_equal "just do it", turn["reasoning_content"]
    assert_equal 40, turn.dig("metrics", "extra", "completion_tokens_details", "reasoning_tokens")
    assert_equal 40, trajectory.dig("final_metrics", "extra", "total_reasoning_tokens")
  end

  def test_harness_data_rides_the_agent_field
    stub_llm(SUBMIT)
    result = agent.run("Just submit.")

    trajectory = as_json(trajectory_for(result, agent: { name: "custom", version: "9.9",
                                                         extra: { agent_config: { step_limit: 3 } } }))

    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")
    assert_equal "custom", trajectory.dig("agent", "name")
    assert_equal "9.9", trajectory.dig("agent", "version")
    assert_equal 3, trajectory.dig("agent", "extra", "agent_config", "step_limit")
  end

  def test_an_orphan_tool_entry_is_dropped_not_invented_into_a_step
    result = Miniswen::Agent::Result.from_h(
      status: "format_error", submission: nil, steps: 0,
      messages: [{ role: "tool", tool_call_id: "call_1", content: "{}" }],
      cost_source: nil, input_tokens: 0, output_tokens: 0, cached_tokens: 0, thinking_tokens: 0, cost_usd: 0.0
    )

    trajectory = as_json(trajectory_for(result))

    assert_empty trajectory["steps"]
  end

  private

  attr_reader :agent, :fake_env

  def build_agent(model: "test", **)
    @agent = Miniswen::Agent.new(model: model, environment: fake_env, **)
  end
end
