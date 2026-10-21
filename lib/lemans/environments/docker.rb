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
      PROXY_PORT = 3128

      attr_reader :container

      def self.proxy_image
        @proxy_image ||= Config::ImageSpec.dockerfile(Pathname(__dir__).join("docker/proxy/Dockerfile"), slug: "proxy")
      end

      def initialize(image:, resources:, network:, env: {}, labels: {}, logger: nil, build_timeout: nil, ttl: nil)
        super(image:, resources:, network:, env:, labels:, ttl:,
              build_timeout: build_timeout || DEFAULT_BUILD_TIMEOUT)
        @logger = logger
        @name = "lemans-#{SecureRandom.hex(6)}"
        assert_policy_supported!(network)
      end

      def start
        build_image!(image) if image.built?
        start_proxy!(network.hosts) if network.allowlist?
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
        argv = [ "exec", "--user", "0" ]
        env = proxy_env.merge(env) if network.allowlist?
        env.each { |key, value| argv += [ "--env", "#{key}=#{value}" ] }
        # The in-container timeout is what actually kills the process
        argv += [ container, "timeout", timeout.to_i.to_s, "bash", "-c", command ]

        exit_code, output = capture("docker", *argv, timeout: timeout + EXEC_SLACK)
        ExecResult.new(command:, exit_code:, output:, duration: (now - started).round(3))
      end

      def upload(local_path, remote_path)
        docker!("exec", "--user", "0", container, "mkdir", "-p", File.dirname(remote_path.to_s))
        docker!("cp", local_path.to_s, "#{container}:#{remote_path}")
      end

      def download(remote_path, local_path)
        local_path = Pathname(local_path)
        local_path.dirname.mkpath
        docker!("cp", "#{container}:#{remote_path}", local_path.to_s)
      end

      def switch_network_policy!(policy)
        assert_policy_supported!(policy)

        wanted = ("bridge" if policy.public?) || (internal_network if policy.allowlist?)
        networks = connected_networks
        (networks - [ wanted ]).each { docker!("network", "disconnect", it, container) }

        remove_proxy
        start_proxy!(policy.hosts) if policy.allowlist?
        docker!("network", "connect", wanted, container) if wanted && !networks.include?(wanted)

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
      ensure
        remove_proxy
        remove_internal_network
      end

      private

      def assert_policy_supported!(policy)
        return unless policy.allowlist? && policy.ip_targets.any?

        raise ConfigError, "docker: an allowlist takes host names only (#{policy.ip_targets.join(", ")})"
      end

      # The tag is the content digest, so an existing image is the identical thing
      def build_image!(spec)
        exists, = capture("docker", "image", "inspect", spec.name, timeout: HOUSEKEEPING_TIMEOUT)
        return if exists.zero?

        docker!("build", "--tag", spec.name, spec.context_dir.to_s, timeout: build_timeout, on_output: @logger)
      end

      # The task container sits on an internal network with no route out; the
      # proxy is on it and on bridge, so the hosts it allows are the only way out.
      def start_proxy!(hosts)
        image = self.class.proxy_image
        build_image!(image)
        create_internal_network!
        docker!("run", "--detach", "--name", proxy_name, "--network", internal_network,
                *label_args, image.name, *hosts)
        docker!("network", "connect", "bridge", proxy_name)
        wait_for_proxy!
      end

      def wait_for_proxy!(attempts: 50)
        attempts.times do
          _, output = capture("docker", "logs", proxy_name, timeout: HOUSEKEEPING_TIMEOUT)
          return if output.include?("listening on")

          sleep 0.2
        end

        raise InfrastructureError, "docker: the allowlist proxy did not start"
      end

      def proxy_env
        url = "http://#{proxy_name}:#{PROXY_PORT}"
        no_proxy = "localhost,127.0.0.1"
        { "http_proxy" => url, "https_proxy" => url, "HTTP_PROXY" => url, "HTTPS_PROXY" => url,
          "no_proxy" => no_proxy, "NO_PROXY" => no_proxy }
      end

      def create_internal_network!
        exists, = capture("docker", "network", "inspect", internal_network, timeout: HOUSEKEEPING_TIMEOUT)
        return if exists.zero?

        docker!("network", "create", "--internal", *label_args, internal_network)
      end

      def remove_proxy
        capture("docker", "rm", "--force", proxy_name, timeout: HOUSEKEEPING_TIMEOUT)
      rescue StandardError
        nil
      end

      def remove_internal_network
        capture("docker", "network", "rm", internal_network, timeout: HOUSEKEEPING_TIMEOUT)
      rescue StandardError
        nil
      end

      def proxy_name = "#{@name}-proxy"

      def internal_network = "#{@name}-net"

      def run_args
        args = [ "--detach", "--init", "--name", @name,
                 "--cpus", resources.cpus.to_s, "--memory", "#{resources.memory}m",
                 "--cap-add", "SYS_ADMIN", "--cap-add", "NET_ADMIN", "--security-opt", "apparmor=unconfined",
                 "--entrypoint", "sh" ]
        args += [ "--network", "none" ] if network.none?
        args += [ "--network", internal_network ] if network.allowlist?
        env.each { |key, value| args += [ "--env", "#{key}=#{value}" ] }
        args + label_args + [ image.name, "-c", "tail -f /dev/null" ]
      end

      def label_args = labels.flat_map { |key, value| [ "--label", "#{key}=#{value}" ] }

      def connected_networks
        docker!("inspect", "--format", "{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}", container).split
      end

      def remove
        capture("docker", "rm", "--force", "--volumes", @name, timeout: HOUSEKEEPING_TIMEOUT)
        remove_proxy
        remove_internal_network
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
