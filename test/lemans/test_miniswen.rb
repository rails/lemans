# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class MiniswenTest < Minitest::Test
  # Answers the loop from a script of assistant responses. Token counts and
  # per-call cost are constant; missing tool call ids are assigned like a provider would.
  class ScriptedLLM
    attr_reader :transcripts

    def initialize(responses, cost_usd: 0.01, thinking: nil)
      @responses = responses.dup
      @cost_usd = cost_usd
      @thinking = thinking
      @transcripts = []
      @ids = 0
    end

    def call(messages)
      @transcripts << messages.map { _1[:content] }
      response = @responses.shift or raise "the script ran out of answers"
      tool_calls = (response[:tool_calls] || []).map { _1[:id] ? _1 : _1.merge(id: "call_#{@ids += 1}") }
      { content: response[:content].to_s, thinking: @thinking, tool_calls: tool_calls,
        finish_reason: response.fetch(:finish_reason, tool_calls.empty? ? "stop" : "tool_calls"),
        input_tokens: 100, output_tokens: 20, cached_tokens: 5,
        thinking_tokens: @thinking ? 40 : 0, cost_usd: @cost_usd }
    end

    def cost_source = Lemans::Results::CostSource.agent("scripted")
  end

  # The loop with its model seam stubbed: `complete` reads from a script
  # instead of a provider, so no request leaves the process.
  class ScriptedLoop < Lemans::Miniswen
    def initialize(llm:, **)
      @scripted = llm
      super(model: "scripted", **)
    end

    def cost_source = @scripted.cost_source

    private

    def complete(messages) = @scripted.call(messages)
  end

  # A shell made of a Hash. `echo` behaves like echo, so the submit marker
  # works the way it does in a real sandbox; anything else is looked up.
  class ScriptedShell
    attr_reader :commands

    def initialize(canned = {})
      @canned = canned
      @commands = []
    end

    def exec(command, timeout_sec: nil, env: {})
      @commands << command
      return result(0, command.delete_prefix("echo ")) if command.start_with?("echo ")

      exit_code, output = @canned.fetch(command, [0, ""])
      result(exit_code, output)
    end

    private

    def result(exit_code, output)
      Lemans::Environments::Base::ExecResult.new(command: @commands.last, exit_code: exit_code,
                                                 output: output, duration_sec: 0.0)
    end
  end

  SUBMIT = {
    content: "Done.",
    tool_calls: [{ name: "bash", arguments: { "command" => "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT" } }]
  }.freeze

  def answer(*commands)
    { content: "Let me try.", tool_calls: commands.map { { name: "bash", arguments: { "command" => _1 } } } }
  end

  def build(llm, shell, **)
    ScriptedLoop.new(llm: llm, environment: shell, **)
  end

  def test_it_works_a_task_and_submits
    llm = ScriptedLLM.new([answer("ls /app"), SUBMIT])
    shell = ScriptedShell.new("ls /app" => [0, "hello.txt"])

    result = build(llm, shell).run("List the app directory.")

    assert_equal :submitted, result.status
    assert_equal 2, result.steps
    # The first exec is the uname that fills <system_information>.
    assert_equal ["uname -srvm", "ls /app", "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"], shell.commands
    # The model saw what the command printed, as the mini JSON observation.
    # The last message observes the submit command itself; the ls came before.
    observation = result.messages[-3]

    assert_equal "tool", observation[:role]
    assert_includes observation[:content], '"returncode": 0'
    assert_includes observation[:content], "hello.txt"
    # And the instruction made it into the first user turn.
    assert_includes result.messages[1][:content], "List the app directory."
    assert_in_delta 0.02, result.cost_usd
    assert_equal 200, result.input_tokens
  end

  def test_each_tool_call_in_a_response_runs_and_gets_its_own_observation
    llm = ScriptedLLM.new([answer("echo one", "echo two"), SUBMIT])
    shell = ScriptedShell.new

    result = build(llm, shell).run("task")

    assert_equal ["uname -srvm", "echo one", "echo two",
                  "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"], shell.commands
    assistant = result.messages[2]
    ids = assistant[:tool_calls].map { _1[:id] }

    observed_ids = result.messages[3..4].map { _1[:tool_call_id] }

    assert_equal ids, observed_ids
    assert_includes result.messages[3][:content], "one"
    assert_includes result.messages[4][:content], "two"
  end

  def test_a_submission_stops_the_remaining_tool_calls
    llm = ScriptedLLM.new([answer("echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT", "echo after")])

    result = build(llm, ScriptedShell.new).run("task")

    assert_equal :submitted, result.status
    refute_includes result.messages.filter_map { _1[:observation] }.join, "after"
  end

  def test_a_response_without_tool_calls_is_bounced_back_and_the_model_may_recover
    llm = ScriptedLLM.new([{ content: "no command here" }, answer("true"), SUBMIT])

    result = build(llm, ScriptedShell.new).run("task")

    assert_equal :submitted, result.status
    assert(result.messages.any? { _1[:content].include?("No tool calls found in the response") })
  end

  def test_a_truncated_response_is_told_to_be_concise
    llm = ScriptedLLM.new([{ content: "ramble", finish_reason: "length" }, answer("true"), SUBMIT])

    result = build(llm, ScriptedShell.new).run("task")

    assert_equal :submitted, result.status
    assert(result.messages.any? { _1[:content].include?("reached the output token limit") })
  end

  def test_three_malformed_answers_in_a_row_end_the_run
    llm = ScriptedLLM.new([
                            { content: "nope" },
                            { content: "wrong tool", tool_calls: [{ name: "python", arguments: {} }] },
                            { content: "no arg", tool_calls: [{ name: "bash", arguments: {} }] }
                          ])

    result = build(llm, ScriptedShell.new).run("task")

    assert_equal :format_error, result.status
    assert_equal 3, result.steps
    assert(result.messages.any? { _1[:content].include?("Unknown tool 'python'.") })
    assert(result.messages.any? { _1[:content].include?("Missing 'command' argument") })
  end

  def test_the_step_limit_stops_the_loop_before_the_next_paid_call
    llm = ScriptedLLM.new([answer("true"), answer("true"), answer("true")])

    result = build(llm, ScriptedShell.new, step_limit: 2).run("task")

    assert_equal :step_limit, result.status
    assert_equal 2, result.steps
  end

  def test_the_cost_limit_stops_the_loop
    llm = ScriptedLLM.new(Array.new(5) { answer("true") }, cost_usd: 3.0)

    result = build(llm, ScriptedShell.new, cost_limit_usd: 5.0).run("task")

    assert_equal :cost_limit, result.status
    assert_equal 2, result.steps
    assert_in_delta 6.0, result.cost_usd
  end

  def test_the_time_limit_stops_the_loop
    ticks = [0, 1, 100].each
    llm = ScriptedLLM.new([answer("true"), answer("true")])

    result = build(llm, ScriptedShell.new, time_limit_sec: 60, clock: -> { ticks.next }).run("task")

    assert_equal :time_limit, result.status
    assert_equal 1, result.steps
  end

  def test_a_flood_of_output_reaches_the_model_elided_head_and_tail
    llm = ScriptedLLM.new([answer("make noise"), SUBMIT])
    shell = ScriptedShell.new("make noise" => [0, "x" * 50_000])

    result = build(llm, shell).run("task")

    observation = result.messages[-3][:content]

    assert_operator observation.length, :<, 12_000
    assert_includes observation, '"output_head"'
    assert_includes observation, '"elided_chars": 40000'
    assert_includes observation, "Output too long."
  end

  def test_an_unpriced_model_is_reported_as_unknown_cost_not_as_free
    llm = ScriptedLLM.new([answer("true"), SUBMIT], cost_usd: nil)

    result = build(llm, ScriptedShell.new).run("task")

    assert_equal :submitted, result.status
    assert_nil result.cost_usd
  end
end

class MiniswenAdapterTest < Minitest::Test
  include CorpusFixture

  SUBMIT = MiniswenTest::SUBMIT

  def answer(*commands, content: "Let me try.")
    { content: content, tool_calls: commands.map { { name: "bash", arguments: { "command" => _1 } } } }
  end

  def build_agent(responses, cost_usd: 0.01, thinking: nil)
    bench = load_bench
    agent = Lemans::Agents::Base.build("miniswen", profile: bench.agent)
    llm = MiniswenTest::ScriptedLLM.new(responses, cost_usd: cost_usd, thinking: thinking)
    agent.define_singleton_method(:loop_for) { |env| MiniswenTest::ScriptedLoop.new(llm: llm, environment: env) }
    [agent, load_task(bench)]
  end

  def call(agent, task)
    Dir.mktmpdir do |dir|
      logs_dir = Pathname(dir)
      result = agent.call(MiniswenTest::ScriptedShell.new, task: task, logs_dir: logs_dir)
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

    assert_raises(Lemans::AccountingError) { call(agent, task) }
  end

  def test_the_profile_config_reaches_the_loop_mini_style
    bench = load_bench
    agent = Lemans::Agents::Base.build("miniswen", profile: bench.agent)
    loop_config = agent.send(:loop_for, MiniswenTest::ScriptedShell.new)

    assert_equal 100, loop_config.instance_variable_get(:@step_limit)
    assert_equal 300, loop_config.instance_variable_get(:@exec_timeout_sec)
    assert_in_delta 5.0, loop_config.instance_variable_get(:@cost_limit_usd)
  end
end
