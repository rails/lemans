# frozen_string_literal: true

require "test_helper"
require "daytona"

# The session machinery: long commands run detached and are polled, short
# ones go direct, and a command that outruns its budget kills the session
# rather than trusting the filesystem.
class ShellTest < Minitest::Test
  SHORT = Lemans::Environments::Daytona::Shell::SHORT_COMMAND_SEC

  def test_a_short_command_goes_straight_through
    process = FakeProcess.new
    shell = build_shell(process)

    result = shell.exec("ls", timeout_sec: 30, env: {})

    assert_equal 0, result.exit_code
    assert_equal "ok", result.output
    assert_empty process.session_commands
  end

  def test_a_long_command_runs_detached_and_is_polled_to_its_exit_code
    process = FakeProcess.new(status_after: 2, status: "3", log: "the suite ran")
    shell = build_shell(process)

    result = shell.exec("bin/rails test", timeout_sec: SHORT + 1, env: { "K" => "v" })

    assert_equal 3, result.exit_code
    assert_equal "the suite ran", result.output
    session_command = process.session_commands.fetch(0)

    assert_includes session_command, "export K=v"
    assert_includes session_command, "bin/rails test"
    # The scratch files were removed before the model's next look at /tmp.
    assert(process.direct_commands.any? { _1.start_with?("rm -f /tmp/lemans-") })
  end

  def test_a_command_that_outruns_its_budget_kills_the_session_and_reports_124
    process = FakeProcess.new(status_after: Float::INFINITY, log: "still going")
    shell = build_shell(process)

    result = shell.exec("sleep 1000", timeout_sec: SHORT + 1, env: {})

    assert_equal 124, result.exit_code
    assert_equal "still going", result.output
    assert_equal 1, process.deleted_sessions.size
    # A replacement session exists for whatever runs next.
    assert_equal 2, process.created_sessions.size
    refute_equal(*process.created_sessions)
  end

  def test_a_status_poll_survives_a_dropped_connection
    process = FakeProcess.new(status_after: 1, status: "0", log: "fine", drop_polls: 2)
    shell = build_shell(process)

    result = shell.exec("make", timeout_sec: SHORT + 1, env: {})

    assert_equal 0, result.exit_code
  end

  # --- fakes ---

  FakeSandbox = Struct.new(:process)

  # Scripted toolbox process: direct exec answers by command shape, session
  # commands are recorded, the status file "appears" after N polls.
  class FakeProcess
    attr_reader :direct_commands, :session_commands, :created_sessions, :deleted_sessions

    Response = Struct.new(:exit_code, :result)

    def initialize(status_after: 0, status: "0", log: "", drop_polls: 0)
      @status_after = status_after
      @status = status
      @log = log
      @drop_polls = drop_polls
      @polls = 0
      @direct_commands = []
      @session_commands = []
      @created_sessions = []
      @deleted_sessions = []
    end

    def create_session(id) = @created_sessions << id

    def delete_session(id) = @deleted_sessions << id

    def execute_session_command(session_id:, req:)
      @session_commands << req.command
    end

    def exec(command:, env: nil, timeout: nil)
      @direct_commands << command
      case command
      when /\Acat .*status/ then poll
      when /\Atail / then Response.new(0, @log)
      else Response.new(0, "ok")
      end
    end

    private

    def poll
      @polls += 1
      raise ::Daytona::Sdk::Error, "Connection timed out" if @polls <= @drop_polls
      return Response.new(0, "") if @polls <= @status_after

      Response.new(0, @status)
    end
  end

  private

  # Real clocks and real sleeps have no place in a unit test: the clock jumps
  # a minute per glance, so deadlines expire on schedule.
  def build_shell(process)
    shell = Lemans::Environments::Daytona::Shell.new(FakeSandbox.new(process))
    def shell.sleep(_seconds) = nil

    ticks = 0
    shell.define_singleton_method(:now) { (ticks += 1) * 60 }
    shell
  end
end
