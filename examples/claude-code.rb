# frozen_string_literal: true

# Claude Code as a lemans agent: the CLI runs headless inside the sandbox.
#
#   lemans -r ./examples/claude-code.rb run --agent claude-code --model claude-sonnet-5-5
#
# A `#<effort>` suffix sets the effort level (low, medium, high, xhigh, max):
# `--model claude-sonnet-5-5#high`.
#
# Credentials: export CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`, uses a
# Claude subscription) or ANTHROPIC_API_KEY.
#
# The sandbox image needs bash and curl: the installer pulls the native binary
# while the setup network is open. To skip that per trial (recommended), bake it into the image:
#
#   RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh && \
#       bash /tmp/claude-install.sh && rm /tmp/claude-install.sh
#
# The agent phase only needs the API:
#
#   agent:
#     environment:
#       network:
#         mode: allowlist
#         hosts: [api.anthropic.com]

require "json"
require "shellwords"
require "tempfile"

class ClaudeCodeAgent < Lemans::Agent
  NAME = "claude-code"

  CREDENTIALS = %w[CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY].freeze
  PATH = "export PATH=$HOME/.local/bin:$PATH;"
  API_HOST = "api.anthropic.com"
  STREAM_PATH = "/tmp/lemans-claude.jsonl"

  OUTCOMES = {
    "success" => :completed,
    "error_max_turns" => :step_limit_reached,
    "error_max_budget_usd" => :cost_ceiling_reached
  }.freeze

  def initialize(...)
    super
    raise Lemans::ConfigError, "claude-code: export one of #{CREDENTIALS.join(", ")}" if ENV.slice(*CREDENTIALS).empty?

    policy = profile.environment.network
    return if policy.public? || policy.domains.include?(API_HOST)

    raise Lemans::ConfigError, "claude-code: the agent network must reach #{API_HOST} " \
                               "(agent.environment.network: public, or an allowlist listing it)"
  end

  def install(_task, environment)
    environment.exec!("set -o pipefail; #{PATH} command -v claude || { curl -fsSL https://claude.ai/install.sh | bash && command -v claude; }",
                      timeout: 300)
  end

  # The raw stream stays as the claude.jsonl artifact; the trajectory is its ATIF
  # form (miniswen-compatible, so lemans-viewer and the analysis scripts read it)
  def run(task, environment, history: nil)
    finished = environment.exec("#{command_for(task)} > #{STREAM_PATH}", timeout:, env: claude_env)
    stream = download_stream(environment)
    artifacts = stream ? { "claude.jsonl" => stream } : {}
    trajectory = (Trajectory.new(stream, model: model.to_s, instruction: task.instruction) if stream)
    if finished.exit_code == 124
      return Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(:agent_timeout), usage: unknown_usage,
                                         trajectory:, artifacts:)
    end

    report = result_from(stream)
    unless report
      return Lemans::Agent::Response.new(trajectory:, artifacts:, error: "claude-code: no result in the stream " \
                                                                         "(exit #{finished.exit_code}): #{finished.output.to_s[0, 2000]}")
    end

    # A failed API call (bad credentials, overload) still reports "success"
    outcome = OUTCOMES[report["subtype"]] unless report["subtype"] == "success" && report["is_error"]
    usage = usage_for(report)
    raw_result = JSON.generate(report)
    unless outcome
      return Lemans::Agent::Response.new(usage:, raw_result:, trajectory:, artifacts:, error: report["result"] || report["subtype"])
    end

    Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(outcome), usage:, raw_result:, trajectory:, artifacts:)
  end

  # A stream-json transcript as an ATIF-v1.7 document, laid out like miniswen's:
  # a system step (the session's init event), the task as the user step, one agent
  # step per API response, and each tool result as an observation on the step that
  # called it. Claude-specific fields that ATIF has no slot for go to `extra`.
  #
  # Thinking text is empty unless the API returned it: Claude 5 models default to
  # `display: "omitted"` (signature only), so `reasoning_content` is often absent;
  # `extra.thinking` still records the blocks, their display mode and duration.
  class Trajectory
    SCHEMA_VERSION = "ATIF-v1.7"
    NOTES = "converted from a Claude Code stream-json transcript; total_steps counts API responses (agent steps). " \
            "metrics.prompt_tokens = input + cache reads + cache writes; Claude Code reports no per-step cost. " \
            "Claude-specific fields are kept under extra"

    INIT_KEYS = %w[claude_code_version cwd model permissionMode tools mcp_servers agents skills plugins output_style
                   fast_mode_state capabilities].freeze
    RESULT_KEYS = %w[subtype is_error terminal_reason stop_reason num_turns duration_ms duration_api_ms ttft_ms
                     permission_denials subagent_stats safety_stops api_error_status modelUsage].freeze

    attr_accessor :session_id

    def initialize(stream, model:, instruction: nil)
      @events = stream.to_s.each_line.filter_map { JSON.parse(it) rescue nil }
      @model = model
      @instruction = instruction
    end

    def to_atif
      rate_limits = events_of("rate_limit_event").filter_map { it["rate_limit_info"] }
      {
        schema_version: SCHEMA_VERSION,
        session_id: session_id || init["session_id"],
        agent: { name: NAME, version: init["claude_code_version"], model_name: @model,
                 extra: { init: init.slice(*INIT_KEYS) } }.compact,
        steps: steps,
        notes: NOTES,
        final_metrics: final_metrics,
        extra: {
          status: report["subtype"], submission: report["result"], error: (report["result"] if report["is_error"]),
          result: report.slice(*RESULT_KEYS), claude_session_id: init["session_id"],
          rate_limits: (rate_limits unless rate_limits.empty?),
          estimated_thinking_tokens: events_of("system", "thinking_tokens").sum { it["estimated_tokens_delta"].to_i }.nonzero?
        }.compact
      }.compact
    end

    private

    attr_reader :events

    def init = @init ||= events.find { it["type"] == "system" && it["subtype"] == "init" } || {}
    def report = @report ||= events.reverse.find { it["type"] == "result" } || {}
    def events_of(type, subtype = nil) = events.select { it["type"] == type && (subtype.nil? || it["subtype"] == subtype) }

    def steps
      @steps ||= begin
        list = [ { step_id: 0, source: "system", message: "" } ]
        list << { step_id: 0, source: "user", message: @instruction } if @instruction
        by_call = {}
        by_message = {}
        events.each do |event|
          case event["type"]
          when "assistant" then agent_event(event, list, by_call, by_message)
          when "user" then tool_results(event, by_call)
          when "system" then task_event(event, by_call) if event["subtype"].to_s.start_with?("task_")
          end
        end
        list.each_with_index { |step, i| step[:step_id] = i + 1 }
      end
    end

    # One API response arrives as one event per content block, sharing the message id and
    # usage. Subagents (parent_tool_use_id set) interleave with the main agent, so blocks
    # are joined by message id, not by position.
    def agent_event(event, list, by_call, by_message)
      message = event["message"] || {}
      step = by_message[message["id"]] if message["id"]
      unless step
        step = { step_id: 0, timestamp: event["timestamp"], source: "agent", message: "", model_name: message["model"] || @model,
                 metrics: metrics_for(message["usage"] || {}), llm_call_count: 1,
                 extra: { message_id: message["id"], request_id: event["request_id"], parent_tool_use_id: event["parent_tool_use_id"] }.compact }
        list << step
        by_message[message["id"]] = step if message["id"]
      end
      extra = step[:extra]
      extra[:stop_reason] = message["stop_reason"] if message["stop_reason"]
      extra[:stop_details] = message["stop_details"] if message["stop_details"]

      Array(message["content"]).each do |block|
        case block["type"]
        when "text"
          step[:message] = [ step[:message], block["text"].to_s ].reject(&:empty?).join("\n\n")
        when "thinking", "redacted_thinking"
          text = block["thinking"].to_s
          step[:reasoning_content] = [ step[:reasoning_content].to_s, text ].reject(&:empty?).join("\n\n") unless text.empty?
          thinking = (extra[:thinking] ||= { blocks: 0, redacted: 0 })
          thinking[:blocks] += 1
          thinking[:redacted] += 1 if text.empty?
          thinking[:display] = event["thinking_display"] if event["thinking_display"]
          thinking[:duration_ms] = thinking[:duration_ms].to_i + event["thinking_duration_ms"].to_i if event["thinking_duration_ms"]
        when "tool_use"
          (step[:tool_calls] ||= []) << { tool_call_id: block["id"], function_name: block["name"], arguments: block["input"] || {} }
          by_call[block["id"]] = step
        end
      end
    end

    def tool_results(event, by_call)
      details = event["tool_use_result"]
      meta = Array(event["tool_result_meta"]).to_h { [ it["id"], it.except("id") ] }
      Array(event.dig("message", "content")).each do |block|
        next unless block.is_a?(Hash) && block["type"] == "tool_result" && (step = by_call[block["tool_use_id"]])

        extra = { is_error: block["is_error"], timestamp: event["timestamp"], meta: meta[block["tool_use_id"]] }
        extra.merge!(details.slice("stderr", "interrupted", "isImage", "noOutputExpected", "backgroundTaskId")) if details.is_a?(Hash)
        (step[:observation] ||= { results: [] })[:results] << {
          source_call_id: block["tool_use_id"], content: content_text(block["content"]), extra: extra.compact
        }
      end
    end

    # Background shell tasks: started, then a notification when they finish
    def task_event(event, by_call)
      return unless (step = by_call[event["tool_use_id"]])

      ((step[:extra][:background_tasks] ||= {})[event["task_id"]] ||= {}).merge!(
        event.slice("description", "is_backgrounded", "task_type", "status", "summary", "output_file").compact
      )
    end

    def content_text(content)
      return content.to_s unless content.is_a?(Array)

      content.map { it["type"] == "text" ? it["text"] : JSON.generate(it) }.join("\n")
    end

    # The stream carries each message's usage as of its first block: the prompt side is
    # final, the output count is a start-of-message snapshot, so completion_tokens is left
    # out (final_metrics has the session totals)
    def metrics_for(usage)
      read = usage["cache_read_input_tokens"].to_i
      write = usage["cache_creation_input_tokens"].to_i
      {
        prompt_tokens: usage["input_tokens"].to_i + read + write,
        cached_tokens: read,
        extra: { prompt_tokens_details: { cached_tokens: read, cache_creation_tokens: write, cache_creation: usage["cache_creation"] }.compact,
                 output_tokens_snapshot: usage["output_tokens"],
                 service_tier: usage["service_tier"], inference_geo: usage["inference_geo"], speed: usage["speed"] }.compact
      }
    end

    # Totals over every model of the session: `usage` covers only the main model, while
    # subagents (another model, too) show up in modelUsage and in total_cost_usd
    def final_metrics
      totals = ClaudeCodeAgent.token_totals(report)
      {
        total_prompt_tokens: totals[:input],
        total_completion_tokens: totals[:output],
        total_cached_tokens: totals[:cached],
        total_cost_usd: report["total_cost_usd"],
        total_steps: steps.count { it[:source] == "agent" },
        extra: { total_reasoning_tokens: totals[:thinking].nonzero?, total_cache_creation_tokens: totals[:cache_write],
                 subagent_steps: steps.count { it.dig(:extra, :parent_tool_use_id) }.nonzero?,
                 by_model: report["modelUsage"], num_turns: report["num_turns"] }.compact
      }.compact
    end
  end

  private

  def command_for(task)
    argv = [ "claude", "-p", task.instruction, "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions",
             "--no-session-persistence", "--max-turns", profile.step_limit ]
    name, effort = model.to_s.split("#", 2)
    argv += [ "--model", name ] unless name.to_s.empty?
    argv += [ "--effort", effort ] if effort
    argv += [ "--max-budget-usd", profile.cost_limit ] if profile.cost_limit
    "#{PATH} cd #{Shellwords.escape(task.environment.workdir)} && #{argv.map { Shellwords.escape(it.to_s) }.join(" ")}"
  end

  def download_stream(environment)
    Tempfile.create(%w[claude .jsonl]) do |file|
      environment.download(STREAM_PATH, file.path)
      File.read(file.path)
    end
  rescue Lemans::InfrastructureError
    nil
  end

  # The session ends with a "result" event: outcome, usage, and cost
  def result_from(stream)
    stream.to_s.each_line.reverse_each do |line|
      event = JSON.parse(line)
      return event if event["type"] == "result"
    rescue JSON::ParserError
      next
    end
    nil
  end

  # IS_SANDBOX lets --dangerously-skip-permissions run as root
  def claude_env
    ENV.slice(*CREDENTIALS).merge("IS_SANDBOX" => "1", "DISABLE_AUTOUPDATER" => "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1")
  end

  # Token totals over all models of a session. The result's `usage` counts only the main
  # model; subagents (often another model) are only in modelUsage. Falls back to `usage`
  # for streams without modelUsage.
  def self.token_totals(report)
    models = report["modelUsage"]
    if models.is_a?(Hash) && !models.empty?
      sum = ->(key) { models.values.sum { it[key].to_i } }
      read = sum.("cacheReadInputTokens")
      write = sum.("cacheCreationInputTokens")
      return { input: sum.("inputTokens") + read + write, output: sum.("outputTokens"), cached: read, cache_write: write,
               thinking: sum.("thinkingTokens") }
    end

    usage = report.fetch("usage", {})
    read = usage["cache_read_input_tokens"].to_i
    write = usage["cache_creation_input_tokens"].to_i
    { input: usage["input_tokens"].to_i + read + write, output: usage["output_tokens"].to_i, cached: read, cache_write: write,
      thinking: usage.dig("output_tokens_details", "thinking_tokens").to_i }
  end

  def usage_for(report)
    totals = self.class.token_totals(report)
    Lemans::Result::Usage.new(
      input_tokens: totals[:input],
      output_tokens: totals[:output],
      cached_tokens: totals[:cached],
      steps: report["num_turns"].to_i,
      cost_usd: report["total_cost_usd"],
      cost_source: Lemans::Result::CostSource.build(name: :claude_code, model: report.fetch("modelUsage", {}).keys.first)
    )
  end

  def unknown_usage = Lemans::Result::Usage.zero.with(cost_usd: nil)
end

Lemans::Agents.register(ClaudeCodeAgent::NAME, ClaudeCodeAgent)
