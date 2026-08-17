# frozen_string_literal: true

require "test_helper"

require "miniswen"
require "miniswen/testing"

class MiniswenAgentTest < Minitest::Test
  include Miniswen::Testing

  def setup
    @fake_env = FakeEnv.new
    build_agent
  end

  def test_it_works_a_task_and_submits
    stub_llm("ls /app", SUBMIT)
    fake_env.on("ls /app", "hello.txt")

    result = agent.run("List the app directory.")

    assert_equal :submitted, result.status
    assert_equal 2, result.steps
    # The first exec is the uname that fills <system_information>.
    assert_equal ["uname -srvm", "ls /app", "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"], fake_env.commands
    # The model saw what the command printed, as the mini JSON observation.
    # The last message observes the submit command itself; the ls came before.
    observation = result.messages[-3]

    assert_equal "tool", observation[:role]
    assert_includes observation[:content], '"returncode": 0'
    assert_includes observation[:content], "hello.txt"
    # And the instruction made it into the first user turn.
    assert_includes result.messages[1][:content], "List the app directory."
    assert_equal [Miniswen::Agent::BashTool], RubyLLM::Test.last_request.tool_classes
    assert_in_delta 0.02, result.cost_usd
    assert_equal 200, result.input_tokens
  end

  def test_each_tool_call_in_a_response_runs_and_gets_its_own_observation
    stub_llm({ cmd: ["echo one", "echo two"] }, SUBMIT)

    result = agent.run("task")

    assert_equal ["uname -srvm", "echo one", "echo two",
                  "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"], fake_env.commands
    assistant = result.messages[2]
    ids = assistant[:tool_calls].map { _1[:id] }

    observed_ids = result.messages[3..4].map { _1[:tool_call_id] }

    assert_equal ids, observed_ids
    assert_includes result.messages[3][:content], "one"
    assert_includes result.messages[4][:content], "two"
  end

  def test_a_submission_stops_the_remaining_tool_calls
    stub_llm({ cmd: ["echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT", "echo after"] })

    result = agent.run("task")

    assert_equal :submitted, result.status
    refute_includes result.messages.filter_map { _1[:observation] }.join, "after"
  end

  def test_a_response_without_tool_calls_is_bounced_back_and_the_model_may_recover
    stub_llm({ content: "no command here" }, "true", SUBMIT)

    result = agent.run("task")

    assert_equal :submitted, result.status
    assert(result.messages.any? { _1[:content].include?("No tool calls found in the response") })
  end

  def test_a_truncated_response_is_told_to_be_concise
    stub_llm({ content: "ramble", finish_reason: "length" }, "true", SUBMIT)

    result = agent.run("task")

    assert_equal :submitted, result.status
    assert(result.messages.any? { _1[:content].include?("reached the output token limit") })
  end

  def test_three_malformed_answers_in_a_row_end_the_run
    stub_llm(
      { content: "nope" },
      { content: "wrong tool", tool_calls: [{ name: "python", arguments: {} }] },
      { content: "no arg", tool_calls: [{ name: "bash", arguments: {} }] }
    )

    result = agent.run("task")

    assert_equal :format_error, result.status
    assert_equal 3, result.steps
    assert(result.messages.any? { _1[:content].include?("Unknown tool 'python'.") })
    assert(result.messages.any? { _1[:content].include?("Missing 'command' argument") })
  end

  def test_the_step_limit_stops_the_loop_before_the_next_paid_call
    build_agent(max_steps: 2)
    stub_llm("true", "true", "true")

    result = agent.run("task")

    assert_equal :step_limit, result.status
    assert_equal 2, result.steps
  end

  def test_the_cost_limit_stops_the_loop
    build_agent(max_cost: 0.015)
    stub_llm(*Array.new(5) { "true" })

    result = agent.run("task")

    assert_equal :cost_limit, result.status
    assert_equal 2, result.steps
    assert_in_delta 0.02, result.cost_usd
  end

  def test_the_time_limit_stops_the_loop
    ticks = [0, 1, 100].each
    build_agent(max_time: 60, clock: -> { ticks.next })
    stub_llm("true", "true")

    result = agent.run("task")

    assert_equal :time_limit, result.status
    assert_equal 1, result.steps
  end

  def test_a_flood_of_output_reaches_the_model_elided_head_and_tail
    stub_llm("make noise", SUBMIT)
    fake_env.on("make noise", "x" * 50_000)

    result = agent.run("task")

    observation = result.messages[-3][:content]

    assert_operator observation.length, :<, 12_000
    assert_includes observation, '"output_head"'
    assert_includes observation, '"elided_chars": 40000'
    assert_includes observation, "Output too long."
  end

  def test_an_empty_completion_is_an_infrastructure_failure_not_a_crash
    error = assert_raises(Miniswen::InfrastructureError) { agent.send(:payload, nil) }

    assert_match(/empty completion/, error.message)
  end

  def test_an_unpriced_completion_under_a_cost_ceiling_stops_the_spend_immediately
    build_agent(model: "test-unpriced", max_cost: 5.0)
    stub_llm("true")

    error = assert_raises(Miniswen::AccountingError) { agent.run("task") }

    assert_match(/cost_limit cannot be enforced/, error.message)
  end

  def test_an_unpriced_model_is_reported_as_unknown_cost_not_as_free
    build_agent(model: "test-unpriced")
    stub_llm("true", SUBMIT)

    result = agent.run("task")

    assert_equal :submitted, result.status
    assert_nil result.cost_usd
  end

  def test_the_result_round_trips_through_json
    stub_llm("ls /app", SUBMIT)
    fake_env.on("ls /app", "hello.txt")

    result = agent.run("task")
    restored = Miniswen::Agent::Result.from_h(JSON.parse(JSON.generate(result.to_h)))

    assert_equal result.status, restored.status
    assert_equal result.submission, restored.submission
    assert_equal result.steps, restored.steps
    assert_equal result.cost_usd, restored.cost_usd
    assert_equal result.cost_source, restored.cost_source
    assert_equal result.input_tokens, restored.input_tokens
    # Message keys come back as the loop produced them: symbols everywhere,
    # except tool-call arguments, which keep their provider-style string keys.
    assert_equal result.messages, restored.messages
    assert_equal Miniswen::VERSION, result.to_h[:version]
  end

  def test_provider_env_maps_the_resolved_providers_credentials
    original = RubyLLM.config.ollama_api_base
    RubyLLM.configure { _1.ollama_api_base = "http://localhost:11434/v1" }
    build_agent(model: "ollama/qwen3:8b")

    assert_equal({ "OLLAMA_API_BASE" => "http://localhost:11434/v1" }, agent.provider_env)
  ensure
    RubyLLM.configure { _1.ollama_api_base = original }
  end

  def test_a_local_provider_completion_is_priced_at_zero_not_unknown
    build_agent(model: "ollama/qwen3:8b")

    assert_in_delta 0.0, agent.send(:price, nil)

    source = agent.send(:cost_source)

    assert_equal :local_provider, source.name
    assert_equal "ollama/qwen3:8b ($0.00, local)", source.priced_as
  end

  private

  attr_reader :agent, :fake_env

  def build_agent(model: "test", **)
    @agent = Miniswen::Agent.new(model: model, environment: fake_env, **)
  end
end
