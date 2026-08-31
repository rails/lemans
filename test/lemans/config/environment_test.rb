# frozen_string_literal: true

require "test_helper"

class ConfigEnvironmentTest < Minitest::Test
  Resources = Lemans::Config::Environment::Resources

  def full_config
    {
      "image" => "ruby:3.4",
      "workdir" => "/work",
      "resources" => { "cpus" => 4, "memory" => "2GB", "storage" => "5GB" },
      "build_timeout" => "10m",
      "network" => { "mode" => "none" }
    }
  end

  def test_full_section
    env = Lemans::Config::Environment.from_config(full_config)

    assert_equal "ruby:3.4", env.image
    assert_equal "/work", env.workdir
    assert_equal Resources.new(cpus: 4, memory: 2048, storage: 5120), env.resources
    assert_equal 600.0, env.build_timeout
    assert_equal "none", env.network.mode
  end

  def test_defaults
    env = Lemans::Config::Environment.new

    assert_nil env.image
    assert_equal "/app", env.workdir
    assert_equal Resources.new(cpus: 2, memory: 2048, storage: 5120), env.resources
    assert_equal 600, env.build_timeout
    assert_equal "public", env.network.mode
    assert_empty env.profiles
  end

  def test_partial_resources
    env = Lemans::Config::Environment.from_config(full_config.merge("resources" => { "memory" => "4GB" }))

    assert_equal Resources.new(cpus: 2, memory: 4096, storage: 5120), env.resources
  end

  def test_dockerfile
    env = Lemans::Config::Environment.from_config({ "dockerfile" => "docker/Dockerfile" })

    assert_equal "docker/Dockerfile", env.dockerfile

    error = assert_raises(Lemans::ConfigError) do
      Lemans::Config::Environment.from_config({ "image" => "ruby:3.4", "dockerfile" => "docker/Dockerfile" })
    end

    assert_includes error.message, "mutually exclusive"
  end

  def test_profiles
    env = Lemans::Config::Environment.from_config(full_config.merge(
      "profiles" => {
        "campfire" => { "dockerfile" => "docker/campfire/Dockerfile" },
        "fizzy" => { "image" => "ghcr.io/x/fizzy" }
      }
    ))

    assert_equal "docker/campfire/Dockerfile", env.profiles["campfire"].dockerfile
    assert_equal "ghcr.io/x/fizzy", env.profiles["fizzy"].image

    error = assert_raises(Lemans::ConfigError) do
      Lemans::Config::Environment.from_config({ "profiles" => { "both" => { "image" => "a", "dockerfile" => "b" } } })
    end

    assert_equal "environment.profiles.both: image and dockerfile are mutually exclusive", error.message

    error = assert_raises(Lemans::ConfigError) do
      Lemans::Config::Environment.from_config({ "profiles" => { "bare" => {} } })
    end

    assert_equal "environment.profiles.bare must declare image or dockerfile", error.message
  end

  def test_relative_workdir
    error = assert_raises(Lemans::ConfigError) do
      Lemans::Config::Environment.from_config(full_config.merge("workdir" => "app"))
    end

    assert_includes error.message, "absolute path"
  end
end
