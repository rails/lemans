# frozen_string_literal: true

require "concurrent"
require "daytona"
require "digest"
require "securerandom"
require "shellwords"
require "timeout"

module Lemans
  module Environments
    # Daytona sandboxes. Daytona builds images server-side and enforces the
    # network policy itself; built images become content-named snapshots for reuse.
    class Daytona < Base
      SHORT_COMMAND_SEC = 120
      POLL_INTERVAL_SEC = 2
      MAX_OUTPUT_BYTES = 200_000
      TTL_MINUTES = 120

      # Only reached when a caller builds an environment without a profile.
      # Waiting forever on a wedged build is the one thing that must not happen.
      DEFAULT_BUILD_TIMEOUT_SEC = 600

      # The snapshot service leaks the generated client's own error class
      # instead of wrapping it, so both have to be caught.
      SDK_ERRORS = [::Daytona::Sdk::Error, *::Daytona::Sdk::API_ERROR_CLASSES].freeze

      SNAPSHOT_FAILED = [
        ::DaytonaApiClient::SnapshotState::ERROR,
        ::DaytonaApiClient::SnapshotState::BUILD_FAILED
      ].freeze

      attr_reader :sandbox

      # Two trials that want the same missing snapshot must not both build it;
      # across processes the name collision settles it and the loser waits.
      SNAPSHOT_LOCKS = Concurrent::Map.new

      def self.snapshot_lock(name)
        SNAPSHOT_LOCKS.compute_if_absent(name) { Concurrent::ReentrantReadWriteLock.new }
      end

      # Trials run concurrently, and an unsynchronised memo would build several
      # SDK clients and leak all but one.
      CLIENT = Concurrent::Delay.new { ::Daytona::Daytona.new(credentials) }

      def self.client = CLIENT.value!

      # The CLI stores its key as DAYTONA_TOKEN, the SDK only reads
      # DAYTONA_API_KEY; Config also resolves .env files, so go through it.
      def self.credentials
        config = ::Daytona::Config.new
        config.api_key ||= config.read_env("DAYTONA_TOKEN")
        unless config.api_key || config.jwt_token
          raise ConfigError, "no Daytona credentials: set DAYTONA_API_KEY or DAYTONA_TOKEN"
        end

        config
      end

      def initialize(image:, resources:, network:, env: {}, labels: {}, logger: nil, build_timeout_sec: nil)
        super(image: image, resources: resources, network: network, env: env,
              build_timeout_sec: build_timeout_sec || DEFAULT_BUILD_TIMEOUT_SEC)
        @labels = labels
        @logger = logger
        @session_id = "lemans-#{SecureRandom.hex(6)}"
      end

      def start
        @sandbox = client.create(create_params, on_snapshot_create_logs: @logger)
        sandbox.process.create_session(@session_id)
        self
      rescue ::Daytona::Sdk::Error => e
        raise InfrastructureError, "daytona: could not start sandbox: #{e.message}"
      end

      def exec(command, timeout_sec: nil, env: {})
        started = now
        response =
          if timeout_sec && timeout_sec > SHORT_COMMAND_SEC
            exec_in_session(command, timeout_sec: timeout_sec, env: env)
          else
            exec_directly(command, timeout_sec: timeout_sec, env: env)
          end

        ExecResult.new(command: command, duration_sec: (now - started).round(3), **response)
      rescue ::Daytona::Sdk::Error => e
        raise InfrastructureError, "daytona: exec failed: #{e.message}"
      end

      def upload(local_path, remote_path)
        sandbox.fs.upload_file(local_path.to_s, remote_path.to_s)
      rescue ::Daytona::Sdk::Error => e
        raise InfrastructureError, "daytona: could not upload #{local_path}: #{e.message}"
      end

      def download(remote_path, local_path)
        FileUtils.mkdir_p(File.dirname(local_path.to_s))
        sandbox.fs.download_file(remote_path.to_s, local_path.to_s)
      rescue ::Daytona::Sdk::Error => e
        raise InfrastructureError, "daytona: could not download #{remote_path}: #{e.message}"
      end

      def network_policy=(policy)
        sandbox.update_network_settings(**network_kwargs(policy, for_update: true))
        @network = policy
      rescue ::Daytona::Sdk::Error => e
        raise InfrastructureError, "daytona: could not apply #{policy.mode} policy: #{e.message}"
      end

      # Deleting is the only cleanup that stops the meter. Never raises:
      # cleanup must not replace an otherwise valid result with an exception.
      def stop
        return if @sandbox.nil?

        id = @sandbox.id
        begin
          @sandbox.delete(wait: true)
          @sandbox = nil
        rescue StandardError => e
          warn "lemans: sandbox #{id} may still be running — delete failed: #{e.class}: #{e.message}"
        end
      end

      private

      def client = self.class.client

      # A sandbox inherits the snapshot's resources, so the profile's are
      # stamped into the snapshot at build time.
      def create_params
        ::Daytona::CreateSandboxFromSnapshotParams.new(
          snapshot: ensure_snapshot,
          env_vars: env,
          labels: @labels,
          auto_stop_interval: 0, # a 30-minute agent must not be stopped under it
          auto_delete_interval: 60,
          # A real ceiling: without it a harness that dies mid-run leaves a
          # running sandbox billing forever.
          ttl_minutes: TTL_MINUTES,
          **network_kwargs(network)
        )
      end

      # The lookup name and the whole reuse policy: image digest plus resource
      # shape, because a sandbox inherits resources from its snapshot.
      def snapshot_name
        shape = [image.digest, resources.cpus, resources.memory_mb, resources.storage_mb].join(":")
        "lemans-#{Digest::SHA256.hexdigest(shape)[0, 32]}"
      end

      def ensure_snapshot
        name = snapshot_name
        self.class.snapshot_lock(name).with_write_lock do
          existing = find_snapshot(name)
          existing = discard(existing) if existing && SNAPSHOT_FAILED.include?(existing.state)
          existing ? await_ready(existing) : build_snapshot(name)
        end
        name
      end

      # A failed build keeps the name, so it would wedge every future trial
      # sharing that image. The state is terminal; rebuilding is all that is left.
      def discard(snapshot)
        name = snapshot.name
        client.snapshot.delete(snapshot)

        deadline = now + build_timeout_sec
        while find_snapshot(name)
          raise InfrastructureError, "daytona: failed snapshot #{name} would not go away" if now > deadline

          sleep POLL_INTERVAL_SEC
        end
        nil
      rescue *SDK_ERRORS => e
        raise InfrastructureError, "daytona: could not remove failed snapshot #{name}: #{e.message}"
      end

      def find_snapshot(name)
        client.snapshot.get(name)
      rescue *SDK_ERRORS => e
        return nil if status_code(e) == 404

        raise InfrastructureError, "daytona: could not look up snapshot #{name}: #{e.message}"
      end

      # The SDK's blocking create has no budget of its own, so
      # environment.build_timeout is enforced here or nowhere.
      def build_snapshot(name)
        params = ::Daytona::CreateSnapshotParams.new(
          name: name,
          # A published reference goes in as a one-line `FROM`, not a bare name:
          # Daytona mangles a bare name's `@sha256:` pin into an invalid reference.
          image: image.built? ? ::Daytona::Image.from_dockerfile(image.dockerfile_path.to_s) : base_image,
          resources: daytona_resources
        )
        Timeout.timeout(build_timeout_sec, InfrastructureError,
                        "daytona: snapshot #{name} did not build within #{build_timeout_sec}s") do
          client.snapshot.create(params, on_logs: @logger)
        end
      rescue *SDK_ERRORS => e
        unless status_code(e) == 409
          raise InfrastructureError,
                "daytona: could not build snapshot #{name}: #{e.message}"
        end

        # Another process reached the same missing snapshot first; this trial
        # waits for its build rather than failing.
        taken = find_snapshot(name)
        raise InfrastructureError, "daytona: snapshot #{name} was taken and then vanished" if taken.nil?

        await_ready(taken)
      end

      # A snapshot that exists may still be building for whoever won the race,
      # or deactivated from disuse — a weekly wave will hit that.
      def await_ready(snapshot)
        name = snapshot.name
        deadline = now + build_timeout_sec
        activated = false

        loop do
          state = snapshot.state
          return if state == ::DaytonaApiClient::SnapshotState::ACTIVE

          if SNAPSHOT_FAILED.include?(state)
            raise InfrastructureError, "daytona: snapshot #{name} is #{state}: #{snapshot.error_reason}"
          end

          if state == ::DaytonaApiClient::SnapshotState::INACTIVE && !activated
            client.snapshot.activate(snapshot)
            activated = true
          end

          if now > deadline
            raise InfrastructureError, "daytona: snapshot #{name} was still #{state} after #{build_timeout_sec}s"
          end

          sleep POLL_INTERVAL_SEC
          snapshot = find_snapshot(name)
          raise InfrastructureError, "daytona: snapshot #{name} vanished while it was being waited on" if snapshot.nil?
        end
      rescue *SDK_ERRORS => e
        raise InfrastructureError, "daytona: could not wait for snapshot #{name}: #{e.message}"
      end

      def base_image = ::Daytona::Image.base(image.reference)

      def daytona_resources
        ::Daytona::Resources.new(
          cpu: resources.cpus,
          memory: to_gib(resources.memory_mb),
          disk: to_gib(resources.storage_mb)
        )
      end

      def status_code(error)
        return error.status_code if error.is_a?(::Daytona::Sdk::Error)

        ::Daytona::Sdk.api_error_details(error)[:status_code]
      end

      def exec_directly(command, timeout_sec:, env:)
        response = sandbox.process.exec(
          command: command,
          env: env.empty? ? nil : env,
          timeout: timeout_sec&.to_i
        )
        { exit_code: response.exit_code, output: response.result.to_s }
      end

      # Long commands run detached and are polled, or the agent phase dies at
      # the HTTP timeout. Daytona reports no async exit code, so the command writes its own.
      def exec_in_session(command, timeout_sec:, env:)
        run_id = SecureRandom.hex(6)
        status_file = "/tmp/lemans-#{run_id}.status"
        log_file = "/tmp/lemans-#{run_id}.log"
        exports = env.map { |key, value| "export #{key}=#{Shellwords.escape(value.to_s)}" }.join("\n")

        sandbox.process.execute_session_command(
          session_id: @session_id,
          req: ::Daytona::SessionExecuteRequest.new(
            # A subshell, not a brace group: `set -e`/`exit` would take the
            # session's own shell down and leave the status line unwritten.
            command: "(\n#{exports}\n#{command}\n) > #{log_file} 2>&1\necho $? > #{status_file}",
            run_async: true
          )
        )

        exit_code = await_status(status_file, timeout_sec)
        # A command that outran its budget is still running; the session dies
        # before anything downstream trusts the filesystem.
        terminate_session! if exit_code.nil?

        output = tail(log_file)
        clear_scratch(log_file, status_file)
        { exit_code: exit_code || 124, output: output }
      end

      # Scratch files left in /tmp tell whatever runs next — the model — how
      # it is being run.
      def clear_scratch(*paths)
        exec_directly("rm -f #{paths.map { Shellwords.escape(_1) }.join(" ")}", timeout_sec: 60, env: {})
      rescue ::Daytona::Sdk::Error => e
        warn "lemans: could not clear #{paths.join(", ")}: #{e.message}"
      end

      def terminate_session!
        sandbox.process.delete_session(@session_id)
      rescue StandardError => e
        warn "lemans: could not delete session #{@session_id}: #{e.message}"
      ensure
        @session_id = "lemans-#{SecureRandom.hex(6)}"
        begin
          sandbox.process.create_session(@session_id)
        rescue StandardError => e
          warn "lemans: could not open a replacement session: #{e.message}"
        end
      end

      def await_status(status_file, timeout_sec)
        deadline = now + timeout_sec
        loop do
          status = exec_directly("cat #{status_file} 2>/dev/null", timeout_sec: 30, env: {})
          value = status[:output].to_s.strip
          return Integer(value) if value.match?(/\A\d+\z/)
          return nil if now > deadline

          sleep POLL_INTERVAL_SEC
        end
      end

      def tail(log_file, bytes: MAX_OUTPUT_BYTES)
        exec_directly("tail -c #{bytes} #{log_file} 2>/dev/null", timeout_sec: 60, env: {})[:output].to_s
      end

      def network_kwargs(policy, for_update: false)
        case policy.mode
        when :none
          { network_block_all: true }
        when :public
          for_update ? { network_block_all: false } : {}
        when :allowlist
          if policy.domains.any? && policy.ip_targets.any?
            raise ConfigError, "daytona: an allowlist cannot mix domains and IP targets (#{policy.hosts.join(", ")})"
          end

          {
            network_block_all: false,
            domain_allow_list: policy.domains.join(","),
            network_allow_list: policy.ip_targets.join(",")
          }.reject { |_, value| value == "" }
        end
      end

      def to_gib(megabytes) = [(megabytes / 1024.0).ceil, 1].max

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
