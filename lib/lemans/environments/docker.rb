# frozen_string_literal: true

require "open3"
require "securerandom"

module Lemans
  module Environments
    # Local containers driven through the docker CLI
    class Docker < Environment
      DEFAULT_BUILD_TIMEOUT = 600

      HOUSEKEEPING_TIMEOUT = 60
      MAX_OUTPUT_BYTES = 200_000
      EXEC_SLACK = 30

      attr_reader :container

      def initialize(image:, resources:, network:, env: {}, labels: {}, logger: nil, build_timeout: nil)
        super(image:, resources:, network:, env:, labels:,
              build_timeout: build_timeout || DEFAULT_BUILD_TIMEOUT)
        @logger = logger
        @name = "lemans-#{SecureRandom.hex(6)}"
        assert_policy_supported!(network)
      end

      def start
        build_image! if image.built?
        docker!("run", *run_args, timeout: build_timeout)
        @container = @name
        self
      rescue InfrastructureError => e
        remove
        raise InfrastructureError, "docker: could not start container: #{e.message}"
      end

      def exec(command, timeout: nil, env: {})
        timeout ||= DEFAULT_TIMEOUT
        started = now
        argv = [ "exec" ]
        env.each { |key, value| argv += [ "--env", "#{key}=#{value}" ] }
        # The in-container timeout is what actually kills the process
        argv += [ container, "timeout", timeout.to_i.to_s, "sh", "-c", command ]

        exit_code, output = capture("docker", *argv, timeout: timeout + EXEC_SLACK)
        ExecResult.new(command:, exit_code:, output:, duration: (now - started).round(3))
      end

      def upload(local_path, remote_path)
        docker!("exec", container, "mkdir", "-p", File.dirname(remote_path.to_s))
        docker!("cp", local_path.to_s, "#{container}:#{remote_path}")
      end

      def download(remote_path, local_path)
        local_path = Pathname(local_path)
        local_path.dirname.mkpath
        docker!("cp", "#{container}:#{remote_path}", local_path.to_s)
      end

      def switch_network_policy!(policy)
        assert_policy_supported!(policy)

        if policy.none?
          connected_networks.each { docker!("network", "disconnect", it, container) }
        else
          networks = connected_networks
          docker!("network", "disconnect", "none", container) if networks.include?("none")
          docker!("network", "connect", "bridge", container) unless networks.include?("bridge")
        end

        @network = policy
      end

      def stop
        return if container.nil?

        exit_code, output = capture("docker", "rm", "--force", "--volumes", container, timeout: HOUSEKEEPING_TIMEOUT)
        if exit_code.zero?
          @container = nil
        else
          warn "lemans: container #{container} may still be running — remove failed: #{output.strip}"
        end
      rescue StandardError => e
        warn "lemans: container #{container} may still be running — remove failed: #{e.class}: #{e.message}"
      end

      private

      def assert_policy_supported!(policy)
        return if policy.none? || policy.public?

        raise ConfigError, "docker: #{policy.mode} is not supported (public and none only)"
      end

      # The tag is the content digest, so an existing image is the identical thing
      def build_image!
        exists, = capture("docker", "image", "inspect", image.name, timeout: HOUSEKEEPING_TIMEOUT)
        return if exists.zero?

        docker!("build", "--tag", image.name, image.context_dir.to_s, timeout: build_timeout, on_output: @logger)
      end

      def run_args
        args = [ "--detach", "--init", "--name", @name,
                 "--cpus", resources.cpus.to_s, "--memory", "#{resources.memory}m",
                 "--entrypoint", "sh" ]
        args += [ "--network", "none" ] if network.none?
        env.each { |key, value| args += [ "--env", "#{key}=#{value}" ] }
        labels.each { |key, value| args += [ "--label", "#{key}=#{value}" ] }
        args + [ image.name, "-c", "tail -f /dev/null" ]
      end

      def connected_networks
        docker!("inspect", "--format", "{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}", container).split
      end

      def remove
        capture("docker", "rm", "--force", "--volumes", @name, timeout: HOUSEKEEPING_TIMEOUT)
      rescue StandardError
        nil
      end

      def docker!(*argv, timeout: HOUSEKEEPING_TIMEOUT, on_output: nil)
        exit_code, output = capture("docker", *argv, timeout:, on_output:)
        return output if exit_code.zero?

        raise InfrastructureError, "docker #{argv.first(2).join(" ")} exited #{exit_code}: #{output[0, 2000]}"
      end

      def capture(*argv, timeout:, on_output: nil)
        Open3.popen2e(*argv) do |stdin, pipe, wait|
          stdin.close
          deadline = now + timeout
          output = +""
          timed_out = false

          loop do
            remaining = deadline - now
            if remaining <= 0
              timed_out = true
              kill(wait.pid)
              break
            end
            next unless pipe.wait_readable(remaining)

            chunk = pipe.read_nonblock(65_536, exception: false)
            break if chunk.nil?
            next if chunk == :wait_readable

            on_output&.call(chunk)
            output << chunk
            output = output.byteslice(-MAX_OUTPUT_BYTES..) if output.bytesize > MAX_OUTPUT_BYTES
          end

          status = wait.value
          [ timed_out ? 124 : (status.exitstatus || 1), output.force_encoding(Encoding::UTF_8).scrub ]
        end
      rescue Errno::ENOENT
        raise ConfigError, "docker: CLI not found — install Docker or pick another backend"
      end

      def kill(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
