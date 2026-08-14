# frozen_string_literal: true

require "fileutils"

# A sandbox made of a Hash, so the phases around verification can be tested without
# paying for one. It answers only the commands the harness actually issues.
class FakeEnvironment < Lemans::Environments::Base
  attr_reader :files, :uploads, :commands, :stopped, :policies

  def initialize(files: {}, on_command: nil, fails: nil, refuses: nil)
    super(image: nil, resources: nil, network: nil)
    @files = files
    @on_command = on_command
    @fails = fails
    @refuses = refuses
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

    case command
    when /\Afind (\S+) -type f -print0\z/ then find(Regexp.last_match(1))
    when /\Acat (\S+)\z/ then read(Regexp.last_match(1))
    when /\Arm -f (\S+)\z/ then removed(Regexp.last_match(1))
    else
      @on_command&.call(files)
      result(0, "the suite ran")
    end
  end

  def upload(local_path, remote_path) = @uploads << [local_path.to_s, remote_path.to_s]

  def download(remote_path, local_path)
    FileUtils.mkdir_p(File.dirname(local_path.to_s))
    File.write(local_path.to_s, files.fetch(remote_path.to_s))
  end

  def network_policy=(policy)
    @policies << policy
    @network = policy
  end

  def stop = @stopped = true

  private

  def find(root)
    matches = files.keys.select { _1.start_with?("#{root}/") }
    return result(1, "find: '#{root}': No such file or directory") if matches.empty?

    result(0, matches.join("\0"))
  end

  def read(path) = files.key?(path) ? result(0, files[path]) : result(1, "cat: #{path}: No such file")

  def removed(path)
    files.delete(path)
    result(0, "")
  end

  def result(exit_code, output)
    Lemans::Environments::Base::ExecResult.new(
      command: @commands.last, exit_code: exit_code, output: output, duration_sec: 0.0
    )
  end
end
