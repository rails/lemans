# frozen_string_literal: true

require "concurrent"

require "daytona"

module Lemans
  module Environments
    # Daytona sandboxes. Daytona builds images server-side into reusable content-named
    # snapshots and enforces the network policy itself.
    class Daytona < Base
      TTL_MINUTES = 120

      DEFAULT_BUILD_TIMEOUT = 600

      # Workspace tarballs ride uploads/downloads, so transfers get their own
      # budget through the SDK's streaming API instead of the global HTTP cap.
      TRANSFER_TIMEOUT = 900

      # File transfers ride the SDK's typhoeus/libcurl stack, which segfaults
      # the VM under enough concurrent easy_perform calls (a GC race on string
      # options libcurl is still copying). Transfers are seconds each, so
      # capping them costs little; execs and lifecycle stay fully parallel.
      TRANSFER_SLOTS = Concurrent::Semaphore.new(6)

      SdkTweaks.apply!

      attr_reader :sandbox

      # Trials run concurrently, and an unsynchronised memo would build several
      # SDK clients and leak all but one.
      CLIENT = Concurrent::Delay.new { ::Daytona::Daytona.new(credentials) }

      def self.client = CLIENT.value!

      # The CLI stores its key as DAYTONA_TOKEN, the SDK only reads
      # DAYTONA_API_KEY; Config also resolves .env files, so go through it.
      def self.credentials
        config = ::Daytona::Config.new
        config.api_key ||= config.read_env("DAYTONA_TOKEN")
        raise ConfigError, "no Daytona credentials: set DAYTONA_API_KEY or DAYTONA_TOKEN" unless config.api_key || config.jwt_token

        config
      end

      def initialize(image:, resources:, network:, env: {}, labels: {}, logger: nil, build_timeout: nil)
        super(image:, resources:, network:, env:, labels:,
              build_timeout: build_timeout || DEFAULT_BUILD_TIMEOUT)
        @logger = logger
      end

      def start
        @sandbox = client.create(create_params, on_snapshot_create_logs: @logger)
        @shell = Shell.new(sandbox)
        self
      rescue *Retries::SDK_ERRORS => e
        # A sandbox created but never handed over would bill until its TTL:
        # the caller's ensure can only stop an environment it received.
        stop
        raise InfrastructureError, "daytona: could not start sandbox: #{e.message}"
      end

      def exec(command, timeout: nil, env: {})
        @shell.exec(command, timeout: timeout || DEFAULT_TIMEOUT, env: env)
      rescue *Retries::SDK_ERRORS => e
        raise InfrastructureError, "daytona: exec failed: #{e.message}"
      end

      def upload(local_path, remote_path)
        transfer do
          # An open handle, not a path string: the SDK uploads a non-existent
          # path AS ITS OWN BYTES, so a missing file must die here as ENOENT.
          Pathname(local_path).open("rb") do |file|
            sandbox.fs.upload_file_stream(file, remote_path.to_s, timeout: TRANSFER_TIMEOUT)
          end
        end
      rescue *Retries::SDK_ERRORS => e
        raise InfrastructureError, "daytona: could not upload #{local_path}: #{e.message}"
      end

      def download(remote_path, local_path)
        local_path = Pathname(local_path)
        local_path.dirname.mkpath
        transfer do
          local_path.open("wb") do |file|
            sandbox.fs.download_file_stream(remote_path.to_s, timeout: TRANSFER_TIMEOUT) { file.write(_1) }
          end
        end
      rescue *Retries::SDK_ERRORS, SystemCallError => e
        raise InfrastructureError, "daytona: could not download #{remote_path}: #{e.message}"
      end

      def switch_network_policy!(policy)
        sandbox.update_network_settings(**network_kwargs(policy, for_update: true))
        @network = policy
      rescue *Retries::SDK_ERRORS => e
        raise InfrastructureError, "daytona: could not apply #{policy.mode} policy: #{e.message}"
      end

      # Deleting is the only cleanup that stops the meter. Never raises:
      # cleanup must not replace an otherwise valid result with an exception.
      def stop
        return if @sandbox.nil?

        id = @sandbox.id
        wait = true
        begin
          @sandbox.delete(wait:)
          @sandbox = nil
        rescue StandardError => e
          # VM shutdown: confirming destruction needs threads Ruby no longer
          # grants, but the bare DELETE needs none — the meter still stops.
          if e.is_a?(ThreadError) && wait
            wait = false
            retry
          end
          warn "lemans: sandbox #{id} may still be running — delete failed: #{e.class}: #{e.message}"
        end
      end

      private

      def transfer
        TRANSFER_SLOTS.acquire
        yield
      ensure
        TRANSFER_SLOTS.release
      end

      def client = self.class.client

      # A sandbox inherits the snapshot's resources, so the profile's are
      # stamped into the snapshot at build time.
      def create_params
        ::Daytona::CreateSandboxFromSnapshotParams.new(
          snapshot: snapshot_store.call,
          env_vars: env,
          labels: labels,
          auto_stop_interval: 0, # a 30-minute agent must not be stopped under it
          auto_delete_interval: 60,
          # A real ceiling: without it a harness that dies mid-run leaves a
          # running sandbox billing forever.
          ttl_minutes: TTL_MINUTES,
          **network_kwargs(network)
        )
      end

      def snapshot_store
        SnapshotStore.new(client:, image:, resources:, build_timeout:, logger: @logger)
      end

      def network_kwargs(policy, for_update: false)
        case policy.mode
        when "none"
          { network_block_all: true }
        when "public"
          for_update ? { network_block_all: false } : {}
        when "allowlist"
          raise ConfigError, "daytona: an allowlist cannot mix domains and IP targets (#{policy.hosts.join(", ")})" if policy.domains.any? && policy.ip_targets.any?

          {
            network_block_all: false,
            domain_allow_list: policy.domains.join(","),
            network_allow_list: policy.ip_targets.join(",")
          }.reject { |_, value| value == "" }
        else
          # Silently returning nil would launch under Daytona's default
          # network — the opposite of what this method exists to prevent.
          raise ConfigError, "daytona: unsupported network mode #{policy.mode.inspect}"
        end
      end
    end
  end
end
