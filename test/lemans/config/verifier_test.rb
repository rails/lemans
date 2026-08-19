# frozen_string_literal: true

require "test_helper"

class ConfigVerifierTest < Minitest::Test
  def test_full_section
    verifier = Lemans::Config::Verifier.from_config(
      {
        "timeout" => "5m",
        "setup" => ["apt-get install -y jq"],
        "command" => "bash /grade.sh",
        "preverify" => "git stash",
        "restore" => ["tests"],
        "logs_dir" => "/logs/grade"
      }
    )

    assert_equal 300.0, verifier.timeout
    assert_equal ["apt-get install -y jq"], verifier.setup
    assert_equal "bash /grade.sh", verifier.command
    assert_equal "git stash", verifier.preverify
    assert_equal ["tests"], verifier.restore_paths
    assert_equal "/logs/grade", verifier.logs_dir
    assert_equal "/logs/grade/reward.txt", verifier.reward_path
  end

  def test_defaults
    verifier = Lemans::Config::Verifier.new

    assert_equal 600, verifier.timeout
    assert_empty verifier.setup
    assert_includes verifier.command, "bash /tests/test.sh"
    assert_nil verifier.preverify
    assert_empty verifier.restore_paths
    assert_equal "/logs/verifier/reward.txt", verifier.reward_path
  end

  def test_relative_logs_dir
    error = assert_raises(Lemans::ConfigError) { Lemans::Config::Verifier.from_config({ "logs_dir" => "logs" }) }

    assert_includes error.message, "absolute path"
  end

  def test_restore_paths_confined_to_the_workdir
    assert_raises(Lemans::ConfigError) { Lemans::Config::Verifier.from_config({ "restore" => ["/abs"] }) }
    assert_raises(Lemans::ConfigError) { Lemans::Config::Verifier.from_config({ "restore" => ["../up"] }) }
    assert_raises(Lemans::ConfigError) { Lemans::Config::Verifier.from_config({ "restore" => ["."] }) }
  end
end
