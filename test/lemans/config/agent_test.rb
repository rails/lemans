# frozen_string_literal: true

require "test_helper"

class ConfigAgentTest < Minitest::Test
  def full_config
    {
      "name" => "miniswen",
      "model" => "openrouter/z-ai/glm-5.2",
      "timeout" => "30m",
      "step_limit" => 200,
      "cost_limit" => 5.0,
      "exec_timeout" => "5m",
      "environment" => {
        "network" => { "mode" => "allowlist", "hosts" => [ "openrouter.ai" ] }
      }
    }
  end

  def test_full_section
    agent = Lemans::Config::Agent.from_config(full_config)

    assert_equal "miniswen", agent.name
    assert_equal [ "openrouter/z-ai/glm-5.2" ], agent.models
    assert_equal 1800.0, agent.timeout
    assert_equal 200, agent.step_limit
    assert_in_delta 5.0, agent.cost_limit
    assert_in_delta 300.0, agent.exec_timeout
    assert_equal "allowlist", agent.environment.network.mode
    assert_equal [ "openrouter.ai" ], agent.environment.network.hosts
  end

  def test_minimal_section_with_defaults
    agent = Lemans::Config::Agent.from_config({ "name" => "nop", "model" => "test-model" })

    assert_equal 100, agent.step_limit
    assert_nil agent.cost_limit
    assert_equal 30 * 60, agent.timeout
    assert_equal 300, agent.exec_timeout
    assert_equal "public", agent.environment.network.mode
    assert_nil agent.environment.network.hosts
  end

  def test_missing_model
    error = assert_raises(Lemans::ConfigError) do
      Lemans::Config::Agent.from_config(full_config.except("model"))
    end

    assert_equal "agent.model must be provided", error.message
  end
end
