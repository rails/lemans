# frozen_string_literal: true

require "test_helper"
require "json"

class RunnerTaskTest < Minitest::Test
  include BenchFixture

  class RecordingReporter
    attr_reader :events

    def initialize = @events = []

    def record(event, data = nil) = @events << [event, data]
  end

  def sandbox
    TestEnvironment.new(on_command: ->(files) { files["/logs/verifier/reward.txt"] = "1" })
  end

  def build_task(config, store, reporter: nil)
    Lemans::Runner::Task.new(nil, load_task(config), index: 1, store:, reporter:)
  end

  def test_run_reports_events_and_persists_the_result
    Dir.mktmpdir do |runs_dir|
      config = load_config
      config.load_options(agent: "oracle")
      reporter = RecordingReporter.new
      task = build_task(config, Lemans::Stores::FS.new(runs_dir), reporter:)

      result = Lemans::Environments.stub(:build, ->(*, **) { sandbox }) { task.run }

      assert_predicate task, :finished?
      assert_equal result, task.result
      assert_equal :completed, result.status
      assert_in_delta 1.0, result.reward
      assert_equal "oracle", result.agent
      assert_equal "hello-world", result.task
      assert_equal "openrouter/z-ai/glm-5.2", result.model
      assert_equal 1, result.index
      assert_equal task.id, result.id

      assert_equal %i[started finished], reporter.events.map(&:first)
      assert_equal task, reporter.events.fetch(0).fetch(1)
      assert_equal result, reporter.events.fetch(1).fetch(1)

      written = JSON.parse(Pathname(runs_dir).join("glm-5.2", result.id, "result.json").read, symbolize_names: true)

      assert_equal "completed", written.dig(:outcome, :name)
      assert written.dig(:outcome, :scored)
      assert_equal task.id, written[:trial]
      assert_equal 1, written[:index]
      assert_equal Lemans::VERSION, written[:lemans_version]
      assert_match(/\A[0-9a-f]{16}\z/, written[:profile_digest])
      assert_match(/\A[0-9a-f]{16}\z/, written[:task_digest])
      assert_in_delta 0.0, written.dig(:usage, :cost_usd)
      assert_kind_of Numeric, written[:duration]
      assert_includes written[:phases].map { it[:name] }, "verifier"
    end
  end

  def test_an_invalid_trial_still_leaves_a_result
    Dir.mktmpdir do |runs_dir|
      config = load_config
      config.load_options(agent: "oracle")
      task = build_task(config, Lemans::Stores::FS.new(runs_dir))

      raising = sandbox.tap { it.define_singleton_method(:start) { raise Lemans::InfrastructureError, "the daemon is down" } }
      result = Lemans::Environments.stub(:build, ->(*, **) { raising }) { task.run }

      assert_equal :environment_error, result.status
      assert_predicate result, :invalid?

      written = JSON.parse(Pathname(runs_dir).join("glm-5.2", result.id, "result.json").read, symbolize_names: true)

      assert_nil written[:reward]
      refute written.dig(:outcome, :scored)
      assert_equal "the daemon is down", written.dig(:outcome, :detail)
    end
  end
end
