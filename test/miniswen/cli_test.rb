# frozen_string_literal: true

require_relative "../test_helper"
require "miniswen/cli"
require "miniswen/testing"
require "stringio"
require "tmpdir"
require "json"

class MiniswenCLITest < Minitest::Test
  include Miniswen::Testing

  def build_reporter
    output = StringIO.new
    [ Miniswen::CLI::Reporter.new(output), output ]
  end

  def test_renders_messages_as_readable_agent_blocks
    reporter, output = build_reporter

    reporter.on_message(role: "assistant", content: "I will inspect the code.\nThen I will fix it.")
    reporter.on_tool_call(name: "bash", arguments: { "command" => "ls -la" })
    reporter.on_message(role: "tool", content: "Exit code: 0\n\nREADME.md")

    expected = "● I will inspect the code.\n  Then I will fix it.\n  $ ls -la\n" \
               "↳ Exit code: 0\n  \n  README.md\n"
    assert_equal expected, output.string
  end

  def test_truncates_large_tool_output_in_normal_mode
    reporter, output = build_reporter
    content = "Exit code: 0\n\n#{"a" * 2_000}"

    reporter.on_message(role: "tool", content: content)

    refute_includes output.string, "a" * 1_001
    assert_includes output.string, "characters omitted"
    assert_operator output.string.length, :<, content.length
  end

  def test_keeps_large_tool_output_in_verbose_mode
    output = StringIO.new
    reporter = Miniswen::CLI::Reporter.new(output, verbose: true)
    content = "Exit code: 0\n\n#{"a" * 2_000}"

    reporter.on_message(role: "tool", content: content)

    assert_includes output.string, "a" * 2_000
  end

  def test_does_not_emit_empty_messages_or_commands
    reporter, output = build_reporter

    reporter.on_message(role: "assistant", content: "")
    reporter.on_tool_call(arguments: {})

    assert_empty output.string
  end

  def test_prints_a_summary_to_the_reporter_output
    reporter, output = build_reporter
    result = Struct.new(:messages, :steps, :cost_usd).new([ { content: "Done" } ], 2, 0.15)

    reporter.print_summary(result)

    assert_equal "● Done\n↳ steps=2 · cost=$0.15\n", output.string
  end

  def test_prints_failures_to_the_reporter_output
    reporter, output = build_reporter
    result = Struct.new(:status).new("max_steps")

    reporter.print_failure(result)

    assert_equal "! Miniswen failed: max_steps\n", output.string
  end

  def test_styles_summary_and_failure_like_other_reporter_blocks_on_a_tty
    io = StringIO.new
    io.define_singleton_method(:tty?) { true }
    reporter = Miniswen::CLI::Reporter.new(io)
    result = Struct.new(:messages, :steps, :cost_usd).new([ { content: "Done" } ], 2, 0.15)

    reporter.print_summary(result)
    reporter.print_failure(Struct.new(:status).new("max_steps"))

    assert_equal "\e[36m●\e[0m \e[36mDone\e[0m\n" \
                 "\e[90m↳\e[0m \e[90msteps=2 · cost=$0.15\e[0m\n" \
                 "\e[33m!\e[0m \e[33mMiniswen failed: max_steps\e[0m\n", io.string
  end

  def test_uses_ansi_colors_only_for_a_tty
    io = StringIO.new
    io.define_singleton_method(:tty?) { true }
    Miniswen::CLI::Reporter.new(io).on_message(role: "assistant", content: "done")

    assert_includes io.string, "\e[36m●\e[0m"
    assert_includes io.string, "\e[36mdone\e[0m"
  end

  def parse(*argv)
    original = ARGV.dup
    ARGV.replace(argv)
    cli = Miniswen::CLI.new
    cli.send(:parse_args!)
    cli
  ensure
    ARGV.replace(original)
  end

  def test_parses_the_remote_run_switches
    cli = parse("-q", "--no-refresh-registry", "--results-path=/tmp/result.json",
                "--atif-path=/tmp/trajectory.json", "-m", "ollama/x", "-p", "task")

    assert cli.instance_variable_get(:@quiet)
    assert cli.instance_variable_get(:@skip_registry_refresh)
    assert_equal "/tmp/result.json", cli.instance_variable_get(:@results_path)
    assert_equal "/tmp/trajectory.json", cli.instance_variable_get(:@atif_path)
  end

  def test_write_atif_produces_a_trajectory_document
    Dir.mktmpdir do |dir|
      path = File.join(dir, "trajectory.json")
      cli = parse("--atif-path=#{path}", "-m", "test", "-p", "task")
      result = Miniswen::Agent::Result.from_h(
        status: "submitted", submission: "done", steps: 1,
        messages: [ { role: "assistant", content: "ok", metrics: { prompt_tokens: 1 } } ],
        cost_source: nil, input_tokens: 1, output_tokens: 1, cached_tokens: 0, thinking_tokens: 0, cost_usd: 0.0
      )
      cli.send(:write_atif, result)

      trajectory = JSON.parse(File.read(path))

      assert_equal "ATIF-v1.7", trajectory["schema_version"]
      assert_equal "test", trajectory.dig("agent", "model_name")
    end
  end

  def test_refresh_registry_needs_no_model_or_prompt
    cli = parse("--refresh-registry")

    assert cli.instance_variable_get(:@refresh_registry)
  end

  def run_cli(*argv)
    original = ARGV.dup
    ARGV.replace(argv)
    Miniswen::CLI.new.run
  ensure
    ARGV.replace(original)
  end

  def test_a_crashed_run_still_writes_the_results_and_trajectory_files
    Dir.mktmpdir do |dir|
      results = File.join(dir, "result.json")
      atif = File.join(dir, "trajectory.json")

      assert_raises(RubyLLM::Test::Errors::NoResponseProvidedError) do
        run_cli("-q", "--no-refresh-registry", "--results-path=#{results}",
                "--atif-path=#{atif}", "-m", "test", "-p", "task")
      end

      payload = JSON.parse(File.read(results))

      assert_equal "error", payload["status"]
      assert_includes payload["error"], "NoResponseProvidedError"
      assert_equal "system", payload.dig("messages", 0, "role")

      trajectory = JSON.parse(File.read(atif))

      assert_equal "error", trajectory.dig("extra", "status")
      assert_includes trajectory.dig("extra", "error"), "NoResponseProvidedError"
    end
  end
end
