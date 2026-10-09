# frozen_string_literal: true

require "test_helper"

class AgentsTest < Minitest::Test
  class TestAgent < Lemans::Agent
    NAME = "test-agent"

    def run(_task, _environment) = Response.new(outcome: Lemans::Result::Outcome.new(:completed), usage: Lemans::Result::Usage.zero)
  end

  def teardown
    Lemans::Agents.unregister(TestAgent::NAME)
  end

  def test_register
    Lemans::Agents.register(TestAgent::NAME, TestAgent)
    config = Lemans::Config::Agent.new(TestAgent::NAME, "some/model")

    agent = Lemans::Agents.build(TestAgent::NAME, profile: config, model: "other/model")

    assert_instance_of TestAgent, agent
    assert_equal "other/model", agent.model
    assert_includes Lemans::Agents.names, TestAgent::NAME
    assert_instance_of Lemans::Agents::Oracle, Lemans::Agents.build("oracle", profile: config)
  end

  def test_builtin_names_are_taken
    error = assert_raises(Lemans::ConfigError) { Lemans::Agents.register("oracle", TestAgent) }

    assert_equal "agent \"oracle\" is built in", error.message
  end

  def test_unknown_agent
    Lemans::Agents.register(TestAgent::NAME, TestAgent)

    error = assert_raises(Lemans::ConfigError) do
      Lemans::Agents.build("nope", profile: Lemans::Config::Agent.new("nope", "some/model"))
    end

    assert_equal "unknown agent \"nope\" (known: nop, oracle, miniswen, miniswen-installed, test-agent)", error.message
  end
end
