# frozen_string_literal: true

require "base64"
require "json"
require "shellwords"
require "tempfile"
require "time"

class CodexAgent < Lemans::Agent
  NAME = "codex"

  PATH = "export PATH=$HOME/.local/bin:$PATH;"
  AUTH_HOSTS = %w[chatgpt.com auth.openai.com].freeze
  AUTH_HOME = "/tmp/lemans-codex-home"
  AUTH_PATH = "#{AUTH_HOME}/auth.json".freeze
  STREAM_PATH = "/tmp/lemans-codex.jsonl"

  def self.recoverable? = true

  def initialize(...)
    super
    @auth_file = File.expand_path(ENV["LEMANS_CODEX_AUTH_FILE"] || File.join(ENV.fetch("CODEX_HOME", "~/.codex"), "auth.json"))

    # Cost estimates are available only after Codex exits, so they cannot enforce a budget.
    if profile.cost_limit
      raise Lemans::ConfigError, "codex: dollar budgets are unsupported; set agent.cost_limit to null and use agent.timeout"
    end

    policy = profile.environment.network
    unless policy.public? || (policy.allowlist? && (AUTH_HOSTS - policy.domains).empty?)
      raise Lemans::ConfigError, "codex: the agent network must reach #{AUTH_HOSTS.join(", ")} " \
                                 "(agent.environment.network: public, or an allowlist listing them)"
    end

    @auth_json = auth_snapshot
  end

  def install(_task, environment)
    environment.exec!("set -o pipefail; #{PATH} command -v codex || { curl -fsSL https://chatgpt.com/codex/install.sh | sh && command -v codex; }",
                      timeout: 300)
    environment.exec!("install -d -m 700 #{AUTH_HOME}")
    Tempfile.create(%w[lemans-codex-auth .json]) do |file|
      file.write(@auth_json)
      file.flush
      environment.upload(file.path, AUTH_PATH)
    end
    environment.exec!("chmod 600 #{AUTH_PATH}")
  end

  def run(task, environment, history: nil)
    checkpoint = Checkpoint.new(model:, history:)
    version = environment.exec!("#{PATH} codex --version").output.strip.delete_prefix("codex-cli ")
    checkpoint.restore(environment, version:) if history
    remaining = (timeout - checkpoint.elapsed).floor
    return response_for(task, checkpoint, exit_code: 124, output: "agent.timeout already exhausted") unless remaining.positive?

    session_id = checkpoint.session_id if history
    prompt = history ? Checkpoint::CONTINUATION_PROMPT : task.instruction
    finished = environment.exec("#{command_for(task, session_id:, prompt:)} > #{STREAM_PATH}",
                                timeout: remaining, env: { "CODEX_HOME" => AUTH_HOME })
    checkpoint.capture(environment, stream: download_stream(environment), prompt:, version:, elapsed: finished.duration)
    response_for(task, checkpoint, exit_code: finished.exit_code, output: finished.output)
  end

  private

  def response_for(task, checkpoint, exit_code:, output:)
    events = checkpoint.events
    report = checkpoint.report
    usage = usage_for(events, token_usage: checkpoint.token_usage)
    trajectory = Trajectory.new(events:, instruction: task.instruction, model:, usage:, exit_code:,
                                segments: checkpoint.trajectory_segments, version: checkpoint.version,
                                token_usage: checkpoint.token_usage) unless events.empty?
    raw_result = JSON.generate(checkpoint.as_json)
    artifacts = checkpoint.stream.empty? ? {} : { "codex.jsonl" => checkpoint.stream }
    if exit_code == 124
      return Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(:agent_timeout), usage:, trajectory:, raw_result:, artifacts:)
    end

    unless exit_code.zero? && report&.fetch("type") == "turn.completed"
      error = report&.dig("error", "message") || events.reverse.find { it["type"] == "error" }&.fetch("message", nil)
      error ||= "no completed turn in the stream"
      return Lemans::Agent::Response.new(usage:, trajectory:, raw_result:, artifacts:,
                                        error: "codex: #{error} (exit #{exit_code}): #{output.to_s[0, 2000]}")
    end
    unless report["usage"]
      return Lemans::Agent::Response.new(usage:, trajectory:, raw_result:, artifacts:, error: "codex: no usage in the completed turn")
    end

    Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(:completed), usage:, trajectory:, raw_result:, artifacts:)
  end

  def auth_snapshot
    auth = JSON.parse(File.read(@auth_file))
    tokens = auth.fetch("tokens")
    payload = tokens.fetch("access_token").split(".").fetch(1)
    payload += "=" * ((4 - payload.length % 4) % 4)
    claims = JSON.parse(Base64.urlsafe_decode64(payload))
    expires_at = Time.at(Integer(claims.fetch("exp"))).utc
    remaining = expires_at - Time.now
    if remaining < 10 * 60 * 60
      raise Lemans::ConfigError, "codex: access token expires at #{expires_at.iso8601} " \
                                 "(#{(remaining / 3600).round(1)} hours remaining); at least 10 hours are required. " \
                                 "Refresh the host Codex login, update #{@auth_file}, and rerun the benchmark"
    end

    auth["auth_mode"] = "chatgptAuthTokens"
    # Codex requires this field even when the host manages refresh.
    tokens["refresh_token"] = ""
    JSON.generate(auth)
  rescue Errno::ENOENT, Errno::EACCES => e
    raise Lemans::ConfigError, "codex: cannot use #{@auth_file}: #{e.message}; " \
                               "run codex -c 'cli_auth_credentials_store=\"file\"' login, " \
                               "or set LEMANS_CODEX_AUTH_FILE"
  rescue JSON::ParserError, KeyError, IndexError, ArgumentError, TypeError
    raise Lemans::ConfigError, "codex: cannot read access-token expiry from #{@auth_file}; " \
                               "refresh the host Codex login and update this file"
  end

  def command_for(task, session_id: nil, prompt: task.instruction)
    argv = [ "codex", "exec", "--color", "never" ]
    argv << "resume" if session_id
    argv += [ "--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check" ]
    name, effort = model.to_s.split("#", 2)
    argv += [ "--model", name ] unless name.to_s.empty?
    argv += [ "--config", "model_reasoning_effort=#{JSON.generate(effort)}" ] if effort
    argv += [ "--config", 'cli_auth_credentials_store="file"', "--config", 'forced_login_method="chatgpt"' ]
    argv << "--"
    argv << session_id if session_id
    argv << prompt
    "#{PATH} cd #{Shellwords.escape(task.environment.workdir)} && #{argv.map { Shellwords.escape(it.to_s) }.join(" ")}"
  end

  def download_stream(environment)
    Tempfile.create(%w[codex .jsonl]) do |file|
      environment.download(STREAM_PATH, file.path)
      File.read(file.path)
    end
  rescue Lemans::InfrastructureError
    nil
  end

  def usage_for(events, token_usage: nil)
    totals = token_usage ? [ token_usage ] : events.select { it["type"] == "turn.completed" }.filter_map { it["usage"] }.last(1)
    info = priced_model unless totals.empty?
    Lemans::Result::Usage.new(
      input_tokens: totals.sum { it["input_tokens"].to_i },
      output_tokens: totals.sum { it["output_tokens"].to_i },
      cached_tokens: totals.sum { it["cached_input_tokens"].to_i },
      steps: events.count { it["type"] == "item.completed" && it.dig("item", "type") == "command_execution" },
      cost_usd: estimated_cost(totals, info),
      cost_source: cost_source(info)
    )
  end

  def priced_model
    info = RubyLLM.models.find(model.to_s.split("#", 2).first, "openai")
    info if info.input_price_per_million.is_a?(Numeric) && info.output_price_per_million.is_a?(Numeric)
  rescue RubyLLM::ModelNotFoundError
    nil
  end

  # Estimate standard API token cost; subscription billing is separate.
  def estimated_cost(totals, info)
    return unless info

    input = info.input_price_per_million
    output = info.output_price_per_million
    cache_read = info.cache_read_input_price_per_million || input
    cache_write = info.cache_write_input_price_per_million || input
    totals.sum do |tokens|
      cached = tokens["cached_input_tokens"].to_i
      written = tokens["cache_write_input_tokens"].to_i
      # Codex includes cache reads/writes in input and reasoning in output.
      uncached = tokens["input_tokens"].to_i - cached - written
      (uncached * input) + (cached * cache_read) + (written * cache_write) + (tokens["output_tokens"].to_i * output)
    end / 1_000_000.0
  end

  def cost_source(info)
    return unless info

    Lemans::Result::CostSource.build(name: :model_registry, model:,
                                     priced_as: "#{info.provider}/#{info.id}", registry: Miniswen.registry_revision)
  end
end

require_relative "checkpoint"
require_relative "trajectory"

Lemans::Agents.register(CodexAgent::NAME, CodexAgent)
