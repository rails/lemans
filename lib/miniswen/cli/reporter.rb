# frozen_string_literal: true

module Miniswen
  class CLI
    # Prints messages and tool calls in real-time. The renderer deliberately
    # keeps the captured (non-TTY) version plain, which makes it useful in CI
    # and when piping a run to a log file too.
    class Reporter
      private attr_reader :io

      # Tool output can be extremely noisy (for example, a recursive grep or
      # a test runner dumping a log). Keep the normal report useful while
      # allowing -vv to retain the complete output for debugging.
      MAX_TOOL_OUTPUT_CHARS = 1_000

      def initialize(io = $stdout, verbose: false, tool_output: verbose)
        @io = io
        @verbose = verbose
        @tool_output = tool_output
      end

      def on_message(message)
        case message[:role].to_s
        when "assistant"
          write_assistant(message)
        when "tool"
          write_tool(message)
        when "user"
          write_block("!", message[:content], :warning)
        else
          write_block("·", message[:content], :muted)
        end
      end

      # Tool calls are reported separately so the command is visible before
      # its output arrives. It is not added to the trajectory sent to the LLM.
      def on_tool_call(call)
        command = call.dig(:arguments, "command") || call.dig(:arguments, :command)
        return if command.to_s.empty?

        line = style("$ #{command}", :command)
        io.puts("  #{line}")
      end

      def print_summary(result)
        write_assistant(result.messages.last)
        write_block("↳", "steps=#{result.steps} · cost=$#{result.cost_usd}", :muted)
      end

      def print_failure(result)
        write_block("!", "Miniswen failed: #{result.status}", :warning)
      end

      private

      def write_tool(message)
        return write_block("↳", message[:content], :tool) if @tool_output

        exit_code = message.dig(:observation, :exit_code)
        return if exit_code.nil?

        if exit_code.zero?
          write_block("↳", "ok", :muted)
        else
          output = truncate(message.dig(:observation, :output).to_s.strip)
          write_block("!", "not ok: exit #{exit_code}\n#{output}", :warning)
        end
      end

      def write_assistant(message)
        content = message[:content].to_s.strip
        write_block("∴", message[:thinking], :thinking) if @verbose || content.empty?
        write_block("●", content, :assistant)
      end

      def write_block(marker, content, tone)
        text = content.to_s.strip
        return if text.empty?

        text = truncate(text) if %i[tool thinking].include?(tone)
        lines = text.lines(chomp: true)
        io.puts("#{style(marker, tone)} #{style(lines.shift, tone)}")
        lines.each { |line| io.puts("  #{style(line, tone)}") }
      end

      def truncate(text)
        return text if @verbose || text.length <= MAX_TOOL_OUTPUT_CHARS

        head = MAX_TOOL_OUTPUT_CHARS / 2
        tail = MAX_TOOL_OUTPUT_CHARS - head
        omitted = text.length - head - tail
        "#{text[0, head]}\n... [#{omitted} characters omitted] ...\n#{text[-tail, tail]}"
      end

      def style(text, tone)
        return text unless io.respond_to?(:tty?) && io.tty?

        colors = { assistant: 36, tool: 32, warning: 33, command: 35, muted: 90, thinking: 90 }
        "\e[#{colors.fetch(tone)}m#{text}\e[0m"
      end
    end
  end
end
