# frozen_string_literal: true

class CodexAgent::Trajectory
  attr_writer :session_id

  def initialize(events:, instruction:, model:, usage:, exit_code:, segments: nil, version: nil, token_usage: nil)
    @events = events
    @model = model
    @usage = usage
    @exit_code = exit_code
    @segments = segments || [ { prompt: instruction, events: events } ]
    @version = version
    @token_usage = token_usage

    @session_id = thread_id
  end

  def to_atif
    {
      schema_version: "ATIF-v1.7",
      session_id: @session_id,
      agent: { name: CodexAgent::NAME, version: @version || "unknown", model_name: @model,
               extra: { adapter_version: Lemans::VERSION } },
      steps: steps,
      notes: "Steps follow Codex items, not individual model calls; total_steps counts completed command executions. " \
             "Prompts come from Lemans. System prompts, timestamps, and per-call usage are not in the event stream.",
      final_metrics: final_metrics,
      extra: stream_info
    }.compact
  end

  private

  def thread_id = @events.find { it["type"] == "thread.started" }&.fetch("thread_id", nil)

  def steps
    @segments.each_with_object([]) do |segment, steps|
      steps << { step_id: steps.size + 1, source: "user", message: segment.fetch(:prompt) }
      items(segment.fetch(:events)).each { steps << step_for(it, steps.size + 1) }
    end
  end

  def items(events)
    snapshots = {}
    turn = 0
    events.each do |event|
      turn += 1 if event["type"] == "turn.started"
      next unless %w[item.started item.updated item.completed].include?(event["type"])

      item = event.fetch("item")
      key = [ turn, item["id"] ]
      # Updates replace snapshots in place, preserving start order and unfinished items.
      snapshot = snapshots[key] ||= { item: {}, completed: false }
      snapshot[:item].merge!(item)
      snapshot[:completed] = event["type"] == "item.completed"
    end
    snapshots.values
  end

  def step_for(snapshot, step_id)
    item = snapshot[:item]
    step = {
      step_id: step_id, source: "agent", message: "",
      extra: { codex_item_id: item["id"], codex_item_type: item["type"],
               status: item["status"], completed: snapshot[:completed] }.compact
    }
    case item["type"]
    when "agent_message"
      step[:message] = item["text"].to_s
    when "reasoning"
      step[:reasoning_content] = item["text"].to_s
    when "command_execution"
      command_step(step, item, snapshot[:completed])
    when "mcp_tool_call"
      mcp_step(step, item, snapshot[:completed])
    when "file_change"
      heading = item["status"] ? "File changes (#{item['status']})" : "File changes"
      step[:message] = "#{heading}:\n" + item.fetch("changes", []).map { "- #{it['kind']} `#{it['path']}`" }.join("\n")
      step[:extra][:changes] = item["changes"]
    when "todo_list"
      step[:message] = item.fetch("items", []).map { "- [#{it['completed'] ? 'x' : ' '}] #{it['text']}" }.join("\n")
    when "web_search"
      step[:message] = "Web search: #{item['query']}"
      step[:extra][:search] = item.except("id", "type")
    else
      step[:message] = JSON.pretty_generate(item)
    end
    step
  end

  def command_step(step, item, completed)
    call_id = "#{step[:step_id]}:#{item['id']}"
    step[:tool_calls] = [ { tool_call_id: call_id, function_name: "bash", arguments: { command: item["command"].to_s } } ]
    output = item["aggregated_output"].to_s
    return unless completed || !output.empty?

    step[:observation] = { results: [ {
      source_call_id: call_id,
      content: JSON.generate({ output: output, returncode: item["exit_code"] }.compact),
      extra: { exit_code: item["exit_code"], status: item["status"], completed: completed }.compact
    } ] }
  end

  def mcp_step(step, item, completed)
    call_id = "#{step[:step_id]}:#{item['id']}"
    arguments = item["arguments"] || {}
    arguments = { input: arguments } unless arguments.is_a?(Hash)
    step[:tool_calls] = [ { tool_call_id: call_id, function_name: "#{item['server']}.#{item['tool']}",
                           arguments: arguments } ]
    return unless completed || item["result"] || item["error"]

    output = item.slice("result", "error").compact
    step[:observation] = { results: [ {
      source_call_id: call_id, content: JSON.pretty_generate(output),
      extra: { status: item["status"], completed: completed }.compact
    } ] }
  end

  def final_metrics
    metrics = { total_steps: @usage.steps }
    totals = @token_usage ? [ @token_usage ] : @events.select { it["type"] == "turn.completed" }.filter_map { it["usage"] }
    return metrics if totals.empty?

    metrics.merge(
      total_prompt_tokens: @usage.input_tokens,
      total_completion_tokens: @usage.output_tokens,
      total_cached_tokens: @usage.cached_tokens,
      total_cost_usd: @usage.cost_usd,
      extra: { total_reasoning_tokens: totals.sum { it["reasoning_output_tokens"].to_i },
               total_cache_write_tokens: totals.sum { it["cache_write_input_tokens"].to_i },
               cost_source: @usage.cost_source&.to_h }.compact
    ).compact
  end

  def stream_info
    terminal = @events.reverse.find { %w[turn.completed turn.failed].include?(it["type"]) }
    errors = @events.select { %w[turn.failed error].include?(it["type"]) }
    { status: terminal&.fetch("type") || "incomplete", codex_thread_id: thread_id,
      exit_code: @exit_code, errors: errors.empty? ? nil : errors }.compact
  end
end
