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
    FakeEnvironment.new(on_command: ->(files) { files["/logs/verifier/reward.txt"] = "1" })
  end

  def build_task(config, runs_dir, reporter: nil)
    store = Lemans::Runner::ResultStore.new(runs_dir)
    Lemans::Runner::Task.new(nil, load_task(config), index: 1, runs_dir: Pathname(runs_dir), store:, reporter:)
  end

  def test_run_reports_events_and_persists_the_result
    Dir.mktmpdir do |runs_dir|
      config = load_config
      config.load_options(agent: "oracle")
      reporter = RecordingReporter.new
      task = build_task(config, runs_dir, reporter:)

      result = Lemans::Environments.stub(:build, ->(*, **) { sandbox }) { task.run }

      assert_predicate task, :finished?
      assert_equal result, task.result
      assert_equal :completed, result.status
      assert_in_delta 1.0, result.reward
      assert_equal "oracle", result.agent
      assert_equal "hello-world", result.task
      assert_equal "openrouter/z-ai/glm-5.2", result.model
      assert_equal task.id, result.id

      assert_equal %i[started finished], reporter.events.map(&:first)
      assert_equal task, reporter.events.fetch(0).fetch(1)
      assert_equal result, reporter.events.fetch(1).fetch(1)

      # The persisted schema is the wire format older lemans releases read.
      written = JSON.parse(task.dir.join("result.json").read, symbolize_names: true)

      assert_equal "completed", written.dig(:outcome, :name)
      assert written.dig(:outcome, :scored)
      assert_equal task.id, written[:trial]
      assert_in_delta 1.0, written[:reward]
      assert_match(/\A[0-9a-f]{16}\z/, written[:profile_digest])
      assert_match(/\A[0-9a-f]{16}\z/, written[:task_digest])
      assert_in_delta 0.0, written.dig(:usage, :cost_usd)
      assert written[:phases].key?(:verifier)
      assert_kind_of Numeric, written[:duration_sec]
      assert_includes task.dir.to_s, "glm-5.2"
    end
  end

  def test_an_invalid_trial_still_leaves_a_result
    Dir.mktmpdir do |runs_dir|
      config = load_config
      config.load_options(agent: "oracle")
      task = build_task(config, runs_dir)

      raising = ->(*, **) { raise Lemans::InfrastructureError, "the daemon is down" }
      result = Lemans::Environments.stub(:build, raising) { task.run }

      assert_equal :environment_error, result.status
      assert_predicate result, :invalid?

      written = JSON.parse(task.dir.join("result.json").read, symbolize_names: true)

      assert_nil written[:reward]
      refute written.dig(:outcome, :scored)
      assert_equal "the daemon is down", written.dig(:outcome, :detail)
    end
  end
end
