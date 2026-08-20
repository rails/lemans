# frozen_string_literal: true

require "test_helper"

require "miniswen/testing"

class MiniswenAdapterTest < Minitest::Test
  include BenchFixture
  include Miniswen::Testing

  def build_agent(*answers, model: "test", **overrides)
    config = load_config
    agent = Lemans::Agents.build("miniswen", profile: config.agent, model: model)
    stub_llm(*answers, **overrides)
    [agent, load_task(config)]
  end

  def run_agent(agent, task)
    response = agent.run(task, FakeEnv.new)
    trajectory = response.trajectory
    trajectory.session_id = "test-session"
    [response, JSON.parse(JSON.generate(trajectory.to_atif))]
  end

  class TransportFailingMiniswen < Lemans::Agents::Miniswen
    private

    def agent_for(environment)
      super.tap do |agent|
        agent.define_singleton_method(:complete) do |_messages|
          raise ::Miniswen::InfrastructureError,
                "miniswen: the model call failed: Faraday::SSLError: SSL_connect returned=1 errno=107"
        end
      end
    end
  end

  def test_a_model_call_failure_returns_the_trajectory_as_evidence
    config = load_config
    agent = TransportFailingMiniswen.new(profile: config.agent, model: "test")
    task = load_task(config)

    response = agent.run(task, FakeEnv.new)

    assert_predicate response, :error?
    assert_includes response.error, "SSL_connect"
    response.trajectory.session_id = "test-session"
    trajectory = JSON.parse(JSON.generate(response.trajectory.to_atif))

    assert_equal "error", trajectory.dig("extra", "status")
    assert_includes trajectory.dig("extra", "error"), "SSL_connect"
    assert_equal "system", trajectory["steps"].first["source"]
  end

  def test_a_submission_is_a_completed_scored_trial_with_priced_usage
    agent, task = build_agent({ cmd: "echo hello > /app/hello.txt", content: "I made the file." }, SUBMIT)
    response, trajectory = run_agent(agent, task)

    assert_predicate response.outcome, :completed?
    assert_predicate response.outcome, :scored?
    assert_in_delta 0.02, response.usage.cost_usd
    assert_equal 2, response.usage.steps
    assert_equal :model_registry, response.usage.cost_source.name

    assert_equal "ATIF-v1.7", trajectory["schema_version"]
    assert_equal "submitted", trajectory.dig("extra", "status")
    # The task's real instruction reached the model.
    assert(trajectory["steps"].any? { _1["message"].include?("hello.txt") })
  end

  def test_the_trajectory_is_native_atif_with_linked_calls_and_metrics
    agent, task = build_agent({ cmd: "date", content: "Checking the date." }, SUBMIT)
    _response, trajectory = run_agent(agent, task)

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
    agent, task = build_agent({ cmd: "date", content: "Checking." }, SUBMIT, thinking: "the task wants a date")
    _response, trajectory = run_agent(agent, task)

    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")

    agent_step = trajectory["steps"].find { _1["source"] == "agent" }

    assert_equal "the task wants a date", agent_step["reasoning_content"]
    assert_equal 1, agent_step["llm_call_count"]
    assert_equal 40, agent_step.dig("metrics", "extra", "completion_tokens_details", "reasoning_tokens")
    assert_equal 80, trajectory.dig("final_metrics", "extra", "total_reasoning_tokens")
  end

  def test_a_model_that_cannot_format_is_still_scored
    agent, task = build_agent({ content: "no call" }, { content: "still none" }, { content: "never" })
    response, trajectory = run_agent(agent, task)

    assert_predicate response.outcome, :completed?
    assert_equal "3 consecutive responses without a valid bash tool call", response.outcome.detail
    assert_equal "format_error", trajectory.dig("extra", "status")
    assert ATIFSchema.valid?(trajectory), ATIFSchema.errors(trajectory).join("\n")
  end

  def test_tokens_billed_at_an_unknown_rate_are_refused_not_free
    agent, task = build_agent(SUBMIT, model: "test-unpriced")

    assert_raises(Miniswen::AccountingError) { run_agent(agent, task) }
  end

  def test_the_profile_config_reaches_the_loop_mini_style
    config = load_config
    agent = Lemans::Agents.build("miniswen", profile: config.agent)
    loop_config = agent.send(:agent_for, FakeEnv.new)

    assert_equal 100, loop_config.instance_variable_get(:@max_steps)
    assert_equal 300, loop_config.instance_variable_get(:@exec_timeout)
    assert_in_delta 5.0, loop_config.instance_variable_get(:@max_cost)
  end
end
