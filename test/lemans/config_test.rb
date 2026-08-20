# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def load_config = Lemans::Config.load_file(BenchFixture::ROOT.to_s)

  def test_load_file
    config = load_config

    assert_equal 1, config.version
    assert_equal "miniswen", config.agent_name
    assert_equal ["openrouter/z-ai/glm-5.2"], config.models
    assert_equal "allowlist", config.environment.network.mode
    assert_equal 2048, config.environment.resources.memory
    assert_equal "allowlist", config.agent.environment.network.mode
    assert_equal "/logs/verifier/reward.txt", config.verifier.reward_path
  end

  def test_defaults
    config = Lemans::Config.new

    assert_equal "miniswen", config.agent_name
    assert_equal 4, config.concurrency
    assert_equal 1, config.attempts
    assert_equal "daytona", config.backend
    assert_empty config.tasks
  end

  def test_tasks
    task = load_config.tasks.fetch(0)

    assert_equal "hello-world", task.name
    assert_match(/\A[0-9a-f]{16}\z/, task.digest)
  end

  def test_default_dockerfile
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      root.join("environment").mkpath
      root.join("environment/Dockerfile").write("FROM scratch\n")
      root.join("bench.yml").write("version: 1\n")

      config = Lemans::Config.load_file(dir)

      assert_equal root.join("environment/Dockerfile"), config.environment.dockerfile

      root.join("bench.yml").write("environment:\n  image: ruby:3.4\n")
      config = Lemans::Config.load_file(dir)

      assert_nil config.environment.dockerfile

      root.join("bench.yml").write("environment:\n  dockerfile: environment/Dockerfile\n")
      config = Lemans::Config.load_file(dir)

      assert_equal root.join("environment/Dockerfile"), config.environment.dockerfile
    end
  end

  def test_load_options
    config = load_config
    config.load_options(agent: "oracle", model: "test-model", attempts: 3, concurrency: 2, backend: "shell", bench: ".")

    assert_equal "oracle", config.agent_name
    assert_equal ["test-model"], config.models
    assert_equal 3, config.attempts
    assert_equal 2, config.concurrency
    assert_equal "shell", config.backend
  end

  def test_digest
    assert_equal load_config.digest, load_config.digest
    assert_match(/\A[0-9a-f]{16}\z/, load_config.digest)
  end

  def test_missing_bench
    error = assert_raises(Lemans::ConfigError) { Lemans::Config.load_file(BenchFixture::ROOT.parent.to_s) }

    assert_includes error.message, "bench.yml not found"
  end
end
