# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# These tests only verify commands issued, not e2e Docker communcation
class DockerEnvironmentTest < Minitest::Test
  def test_start
    environment = environment_for(
      env: { "API_KEY" => "sk-1" },
      labels: { "lemans.task" => "t1" },
      network: policy("none")
    )
    calls = scripted(environment)

    environment.start

    run = calls.first[:argv]
    assert_equal %w[docker run], run.take(2)
    assert_includes run.each_cons(2).to_a, [ "--cpus", "2" ]
    assert_includes run.each_cons(2).to_a, [ "--memory", "2048m" ]
    assert_includes run.each_cons(2).to_a, [ "--env", "API_KEY=sk-1" ]
    assert_includes run.each_cons(2).to_a, [ "--label", "lemans.task=t1" ]
    assert_equal [ "-c", "tail -f /dev/null" ], run.last(2)
    assert_includes run.each_cons(2).to_a, [ "--network", "none" ]
    assert_equal environment.container, run[run.index("--name") + 1]
    assert_equal environment.build_timeout, calls.first[:timeout]
  end

  def test_switch_network_policy_to_none
    environment, calls = started(answers: { "inspect" => [ 0, "bridge custom " ] })

    environment.switch_network_policy!(policy("none"))

    disconnected = calls.select { it[:argv][1] == "network" }.map { it[:argv][2, 2] }
    assert_equal [ %w[disconnect bridge], %w[disconnect custom] ], disconnected
    assert environment.network.none?
  end

  def test_switch_network_policy_to_public
    environment, calls = started(answers: { "inspect" => [ 0, "none " ] })

    environment.switch_network_policy!(policy("public"))

    network_calls = calls.select { it[:argv][1] == "network" }.map { it[:argv][2, 2] }
    assert_equal [ %w[disconnect none], %w[connect bridge] ], network_calls
    assert environment.network.public?
  end

  def test_exec
    environment, calls = started(answers: { "exec" => [ 3, "went sideways" ] })

    result = environment.exec("bundle exec rake", timeout: 90, env: { "RAILS_ENV" => "test" })

    argv = calls.last[:argv]
    assert_equal [ "timeout", "90", "sh", "-c", "bundle exec rake" ], argv.last(5)
    assert_includes argv.each_cons(2).to_a, [ "--env", "RAILS_ENV=test" ]
    assert_equal 90 + Lemans::Environments::Docker::EXEC_SLACK, calls.last[:timeout]
    assert_equal 3, result.exit_code
    assert_equal "went sideways", result.output
    assert_operator result.duration, :>=, 0
  end

  def test_upload
    environment, calls = started

    environment.upload("/tmp/seed.patch", "/lemans/setup/seed.patch")

    assert_equal [ "docker", "exec", environment.container, "mkdir", "-p", "/lemans/setup" ], calls[-2][:argv]
    assert_equal [ "docker", "cp", "/tmp/seed.patch", "#{environment.container}:/lemans/setup/seed.patch" ], calls[-1][:argv]
  end

  def test_start_reuses_the_image
    Dir.mktmpdir do |dir|
      Pathname(dir).join("Dockerfile").write("FROM ruby:3.4-slim\n")
      image = Lemans::Config::ImageSpec.dockerfile(Pathname(dir).join("Dockerfile"), slug: "a-task")

      cached = environment_for(image:)
      calls = scripted(cached, answers: { "image" => [ 0, "" ] })
      cached.start
      assert_empty(calls.select { it[:argv][1] == "build" })

      fresh = environment_for(image:)
      calls = scripted(fresh, answers: { "image" => [ 1, "no such image" ] })
      fresh.start
      build = calls.find { it[:argv][1] == "build" }[:argv]
      assert_equal [ "--tag", image.name, dir ], build.last(3)
    end
  end

  def test_failed_start_cleanup
    environment = environment_for
    calls = scripted(environment, answers: { "run" => [ 125, "port is already allocated" ] })

    error = assert_raises(Lemans::InfrastructureError) { environment.start }

    assert_match(/could not start container/, error.message)
    removal = calls.find { it[:argv][1] == "rm" }
    assert_equal %w[docker rm --force --volumes], removal[:argv].take(4)
    assert_nil environment.container
  end

  private

  def policy(mode, hosts = nil) = Lemans::Config::NetworkPolicy.new(mode, hosts)

  def reference_image = Lemans::Config::ImageSpec.registry("ghcr.io/lemans/reference:1")

  def resources_with = Lemans::Config::Environment::Resources.new(cpus: 2, memory: 2048, storage: 5120)

  def environment_for(image: reference_image, network: policy("public"), env: {}, labels: {})
    Lemans::Environments::Docker.new(image:, resources: resources_with, network:, env:, labels:)
  end

  def scripted(environment, answers: {})
    calls = []
    environment.define_singleton_method(:capture) do |*argv, timeout:, on_output: nil|
      calls << { argv:, timeout: }
      answers.fetch(argv[1], [ 0, "" ])
    end
    calls
  end

  def started(answers: {}, **options)
    environment = environment_for(**options)
    calls = scripted(environment, answers:)
    environment.start
    calls.clear
    [ environment, calls ]
  end
end
