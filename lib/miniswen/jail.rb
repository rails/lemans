# frozen_string_literal: true

require "json"

require "miniswen/local"

module Miniswen
  # Every command runs inside one bubblewrap sandbox that lives for the whole
  # run: no network, its own pid namespace and /proc, and none of the
  # harness's credentials in the environment. The sandbox is an idle process
  # the commands are entered into, so a server started in one step is still
  # there in the next.
  class Jail < Local
    SECRET_VARIABLES = /(_API_KEY|_TOKEN|_SECRET|_PASSWORD)\z|\A(DAYTONA|LEMANS|MINISWEN|RUBYLLM)_/

    attr_reader :workdir, :child_pid

    def initialize(workdir: Dir.pwd)
      @workdir = workdir

      @holder = nil
      @child_pid = nil
    end

    def start
      info_reader, info_writer = IO.pipe
      error_reader, error_writer = IO.pipe
      @holder = Process.spawn(*holder_command(info_writer),
                              info_writer => info_writer, err: error_writer, in: File::NULL, out: File::NULL,
                              pgroup: true)
      info_writer.close
      error_writer.close

      @child_pid = JSON.parse(info_reader.readpartial(4096)).fetch("child-pid") if info_reader.wait_readable(30)
      raise InfrastructureError, "jail: bwrap did not start: #{fail!(error_reader)}" unless @child_pid

      self
    rescue Errno::ENOENT
      raise InfrastructureError, "jail: bwrap is not installed"
    rescue EOFError, JSON::ParserError, KeyError
      raise InfrastructureError, "jail: bwrap did not start: #{fail!(error_reader)}"
    end

    def stop
      return unless @holder

      Process.kill(:KILL, -@holder)
      Process.wait(@holder)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    ensure
      @holder = nil
    end

    def environment = ENV.to_h.reject { |name, _| name.match?(SECRET_VARIABLES) }

    private

    def holder_command(info_writer)
      [ "bwrap", "--unshare-net", "--unshare-pid", "--die-with-parent",
        "--bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--chdir", workdir,
        "--info-fd", info_writer.fileno.to_s, "--", "sleep", "infinity" ]
    end

    def spawn_arguments(command, env)
      [ environment.merge(env || {}),
        "nsenter", "--target", child_pid.to_s, "--mount", "--pid", "--net", "--wd=#{workdir}",
        "--", "sh", "-c", command ]
    end

    def spawn_options = super.merge(unsetenv_others: true)

    def fail!(error_reader)
      stop
      error_reader.read.to_s.strip
    end
  end
end
