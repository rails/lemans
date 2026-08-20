# frozen_string_literal: true

require "fileutils"

# A sandbox made of a Hash, so the phases around verification can be tested without
# paying for one. It answers only the commands the harness actually issues.
class TestEnvironment < Lemans::Environment
  attr_reader :files, :uploads, :commands, :stopped, :policies

  def initialize(files: {}, on_command: nil, fails: nil, refuses: nil, crashes: nil)
    super(image: nil, resources: nil, network: nil)
    @files = files
    @on_command = on_command
    @fails = fails
    @refuses = refuses
    @crashes = crashes
    @uploads = []
    @commands = []
    @policies = []
    @stopped = false
  end

  def start = self

  def exec(command, timeout: nil, env: {})
    @commands << command
    raise Lemans::InfrastructureError, "the sandbox went away" if @fails&.match?(command)
    return result(1, "no") if @refuses&.match?(command)
    return result(2, "it crashed") if @crashes&.match?(command)

    case command
    when /\Afind (\S+) -type f -print0\z/ then find(Regexp.last_match(1))
    when /\Acat (\S+)\z/ then read(Regexp.last_match(1))
    when /\Arm -f (\S+)\z/ then removed(Regexp.last_match(1))
    when /\Atest -e (\S+)\z/ then present(Regexp.last_match(1))
    when /\Atest -d (\S+)\z/ then directory(Regexp.last_match(1))
    else
      notify_on_command(command)
      result(0, "the suite ran")
    end
  end

  def upload(local_path, remote_path) = @uploads << [ local_path.to_s, remote_path.to_s ]

  def download(remote_path, local_path)
    FileUtils.mkdir_p(File.dirname(local_path.to_s))
    File.write(local_path.to_s, files.fetch(remote_path.to_s))
  end

  def switch_network_policy!(policy)
    @policies << policy
    @network = policy
  end

  def stop = @stopped = true

  private

  def notify_on_command(command)
    return unless @on_command

    @on_command.arity >= 2 ? @on_command.call(files, command) : @on_command.call(files)
  end

  def find(root)
    matches = files.keys.select { it.start_with?("#{root}/") }
    return result(1, "find: '#{root}': No such file or directory") if matches.empty?

    result(0, matches.join("\0"))
  end

  def read(path) = files.key?(path) ? result(0, files[path]) : result(1, "cat: #{path}: No such file")

  def present(path) = files.key?(path) ? result(0, "") : result(1, "")

  def directory(root) = files.keys.any? { it.start_with?("#{root}/") } ? result(0, "") : result(1, "")

  def removed(path)
    files.delete(path)
    result(0, "")
  end

  def result(exit_code, output)
    Lemans::Environment::ExecResult.new(
      command: @commands.last, exit_code: exit_code, output: output, duration: 0.0
    )
  end
end

# A Store made of Hashes, so persistence can be asserted without a filesystem.
class TestStore < Lemans::Store
  attr_reader :results, :artifacts

  def initialize
    super
    @results = []
    @artifacts = {}
  end

  def fetch = results

  def query(task: nil, agent: nil, model: nil, tags: nil)
    matched = results.dup
    matched.select! { Array(task).include?(it.task) } if task
    matched.select! { it.agent == agent } if agent
    matched.select! { it.model == model } if model
    matched.select! { Array(tags).intersect?(it.tags) } if tags
    matched
  end

  def save(result) = results << result

  def save_artifact(_result, contents, path:)
    artifacts[path.to_s] = contents.is_a?(String) ? contents : File.read(contents)
  end
end
