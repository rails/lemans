# frozen_string_literal: true

require "test_helper"

class ConfigNetworkPolicyTest < Minitest::Test
  def from_config(data) = Lemans::Config::NetworkPolicy.from_config(data)

  def test_allowlist
    policy = from_config({ "mode" => "allowlist", "hosts" => %w[openrouter.ai github.com] })

    assert_equal "allowlist", policy.mode
    assert_equal %w[openrouter.ai github.com], policy.hosts
  end

  def test_defaults
    policy = Lemans::Config::NetworkPolicy.new

    assert_equal "public", policy.mode
    assert_nil policy.hosts
  end

  def test_unknown_mode
    error = assert_raises(Lemans::ConfigError) { from_config({ "mode" => "closed" }) }

    assert_includes error.message, "not a network mode"
  end

  def test_hosts_misuse
    assert_raises(Lemans::ConfigError) { from_config({ "mode" => "allowlist" }) }
    assert_raises(Lemans::ConfigError) { from_config({ "mode" => "none", "hosts" => [ "a" ] }) }
  end
end
