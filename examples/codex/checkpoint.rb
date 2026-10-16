# frozen_string_literal: true

class CodexAgent::Checkpoint
  FORMAT = "lemans-codex-session-v1"
  STATE_PATH = "/tmp/lemans-codex-session.tar.gz"
  CONTINUATION_PROMPT = "Continue the interrupted benchmark task from the saved session. " \
                        "The workspace contains the saved changes. Check for interrupted commands and finish the original task."

  def initialize(model:, history: nil)
    @data = history ? JSON.parse(history) : { "format" => FORMAT, "model" => model.to_s, "segments" => [], "elapsed" => 0.0 }

    if history && @data["format"] != FORMAT
      raise Lemans::ConfigError, "codex: agent.result.json has no recovery checkpoint; start a new run with this adapter"
    end
    if @data["model"] != model.to_s
      raise Lemans::ConfigError, "codex: checkpoint model #{@data['model'].inspect} does not match #{model.inspect}"
    end
  rescue JSON::ParserError => e
    raise Lemans::ConfigError, "codex: invalid recovery checkpoint: #{e.message}"
  end

  def session_id = @data["session_id"]
  def version = @data["codex_version"]
  def elapsed = @data.fetch("elapsed")
  def report = @data["result"]
  def token_usage = @data["token_usage"]
  def as_json(**) = @data

  def stream = @data.fetch("segments").map { it.fetch("stream") }.reject(&:empty?).map { it.sub(/\n?\z/, "\n") }.join

  def events = @data.fetch("segments").flat_map { events_from(it.fetch("stream")) }

  def trajectory_segments
    @data.fetch("segments").map { { prompt: it.fetch("prompt"), events: events_from(it.fetch("stream")) } }
  end

  def restore(environment, version:)
    unless session_id && @data["session_state"]
      raise Lemans::ConfigError, "codex: checkpoint has no native session state: #{@data['recovery_error'] || 'session was not created'}"
    end
    if self.version != version
      raise Lemans::ConfigError, "codex: checkpoint requires Codex #{self.version}, but the sandbox has #{version}; " \
                                 "preinstall the matching CLI version in the sandbox image"
    end

    Tempfile.create(%w[lemans-codex-state .tar.gz]) do |file|
      file.binmode
      file.write(Base64.strict_decode64(@data.fetch("session_state")))
      file.flush
      environment.upload(file.path, STATE_PATH)
    end
    environment.exec!("tar -xzf #{STATE_PATH} -C #{CodexAgent::AUTH_HOME}")
  end

  def capture(environment, stream:, prompt:, version:, elapsed:)
    current_events = events_from(stream)
    @data["segments"] << { "stream" => stream.to_s, "prompt" => prompt, "elapsed" => elapsed }
    @data["elapsed"] += elapsed
    @data["codex_version"] = version
    @data["result"] = current_events.reverse.find { %w[turn.completed turn.failed].include?(it["type"]) }
    @data["session_id"] = current_events.find { it["type"] == "thread.started" }&.fetch("thread_id", nil) || session_id
    @data["token_usage"] = report&.fetch("usage", nil) || token_usage
    @data.delete("session_state")
    @data.delete("recovery_error")
    return unless session_id

    rollout = download_rollout(environment)
    @data["token_usage"] = tokens_from(rollout) || token_usage
    archive_state(environment)
    @data["session_state"] = Base64.strict_encode64(download(environment, STATE_PATH))
  rescue Lemans::InfrastructureError => e
    @data["recovery_error"] = e.message
  end

  private

  def events_from(stream)
    stream.to_s.each_line.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end

  def download_rollout(environment)
    pattern = Shellwords.escape("*#{session_id}*.jsonl")
    found = environment.exec("find #{CodexAgent::AUTH_HOME}/sessions -type f -name #{pattern} -print")
    path = found.output.lines.map(&:chomp).sort.last if found.success?
    raise Lemans::InfrastructureError, "codex: no persisted rollout for session #{session_id}" unless path

    download(environment, path)
  end

  def download(environment, path)
    Tempfile.create(%w[lemans-codex-session .data]) do |file|
      environment.download(path, file.path)
      File.binread(file.path)
    end
  end

  def archive_state(environment)
    # Save native indexes alongside the rollouts; auth.json is supplied separately on every run.
    environment.exec!("set -o pipefail; cd #{CodexAgent::AUTH_HOME} && " \
                      "find . -mindepth 1 -maxdepth 1 \\( -name sessions -o -name archived_sessions " \
                      "-o -name 'state_*.sqlite*' -o -name 'thread_history_*.sqlite*' -o -name session_index.jsonl \\) -print0 | " \
                      "tar --null -czf #{STATE_PATH} -T -")
  end

  def tokens_from(rollout)
    records = events_from(rollout)
    responses = records.select { it["type"] == "token_usage_record" }.map { it.fetch("payload") }
    thread_total = responses.reverse.filter_map { it["thread_token_usage"] }.first
    return thread_total if thread_total

    unless responses.empty?
      unique = responses.uniq { it.fetch("response_id") }
      return %w[input_tokens cached_input_tokens cache_write_input_tokens output_tokens reasoning_output_tokens].to_h do |key|
        [ key, unique.sum { it.fetch("usage")[key].to_i } ]
      end
    end

    # Older CLIs emit cumulative token_count snapshots, which must not be summed after resume.
    records.reverse_each do |record|
      next unless record["type"] == "event_msg" && record.dig("payload", "type") == "token_count"

      total = record.dig("payload", "info", "total_token_usage")
      return total if total
    end
    nil
  end
end
