# frozen_string_literal: true

require "concurrent"
require "fileutils"

require "daytona"

module Lemans
  module Environments
    # Daytona sandboxes. Daytona builds images server-side into reusable content-named
    # snapshots and enforces the network policy itself.
    class Daytona < Base
      TTL_MINUTES = 120

      DEFAULT_BUILD_TIMEOUT_SEC = 600

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

      def initialize(image:, resources:, network:, env: {}, labels: {}, logger: nil, build_timeout_sec: nil)
        super(image: image, resources: resources, network: network, env: env,
              build_timeout_sec: build_timeout_sec || DEFAULT_BUILD_TIMEOUT_SEC)
        @labels = labels
        @logger = logger
      end

      def start
        @sandbox = client.create(create_params, on_snapshot_create_logs: @logger)
        @shell = Shell.new(sandbox)
        self
      rescue ::Daytona::Sdk::Error => e
        # A sandbox created but never handed over would bill until its TTL:
        # the caller's ensure can only stop an environment it received.
        stop
        raise InfrastructureError, "daytona: could not start sandbox: #{e.message}"
      end

      def exec(command, timeout: nil, env: {})
        @shell.exec(command, timeout: timeout || DEFAULT_TIMEOUT, env: env)
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

      def client = self.class.client

      # A sandbox inherits the snapshot's resources, so the profile's are
      # stamped into the snapshot at build time.
      def create_params
        ::Daytona::CreateSandboxFromSnapshotParams.new(
          snapshot: snapshot_store.call,
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

      def snapshot_store
        SnapshotStore.new(client: client, image: image, resources: resources,
                          build_timeout_sec: build_timeout_sec, logger: @logger)
      end

      def network_kwargs(policy, for_update: false)
        case policy.mode
        when :none
          { network_block_all: true }
        when :public
          for_update ? { network_block_all: false } : {}
        when :allowlist
          raise ConfigError, "daytona: an allowlist cannot mix domains and IP targets (#{policy.hosts.join(", ")})" if policy.domains.any? && policy.ip_targets.any?

          {
            network_block_all: false,
            domain_allow_list: policy.domains.join(","),
            network_allow_list: policy.ip_targets.join(",")
          }.reject { |_, value| value == "" }
        end
      end
    end
  end
end
