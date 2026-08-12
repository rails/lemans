# frozen_string_literal: true

require "concurrent"
require "daytona"
require "digest"
require "timeout"

module Lemans
  module Environments
    class Daytona
      # Content-named snapshots: one build per image digest × resource shape,
      # reused forever after. Owns lookup, build, activation and the discarding
      # of poisoned builds, plus the locking that keeps two trials from
      # building the same snapshot at once.
      class SnapshotStore
        include Retries

        POLL_INTERVAL_SEC = 2

        SNAPSHOT_FAILED = [
          ::DaytonaApiClient::SnapshotState::ERROR,
          ::DaytonaApiClient::SnapshotState::BUILD_FAILED
        ].freeze

        # Two trials that want the same missing snapshot must not both build
        # it; across processes the name collision settles it and the loser waits.
        LOCKS = Concurrent::Map.new

        def self.lock(name)
          LOCKS.compute_if_absent(name) { Concurrent::ReentrantReadWriteLock.new }
        end

        def initialize(client:, image:, resources:, build_timeout_sec:, logger: nil)
          @client = client
          @image = image
          @resources = resources
          @build_timeout_sec = build_timeout_sec
          @logger = logger
        end

        # Returns the name of a ready snapshot, building one when none exists.
        def call
          self.class.lock(name).with_write_lock do
            existing = find(name)
            existing = discard(existing) if existing && SNAPSHOT_FAILED.include?(existing.state)
            existing ? await_ready(existing) : build(name)
          end
          name
        end

        # The lookup name and the whole reuse policy: image digest plus resource
        # shape, because a sandbox inherits resources from its snapshot.
        def name
          @name ||= begin
            shape = [image.digest, resources.cpus, resources.memory_mb, resources.storage_mb].join(":")
            "lemans-#{Digest::SHA256.hexdigest(shape)[0, 32]}"
          end
        end

        private

        attr_reader :client, :image, :resources, :build_timeout_sec, :logger

        # A failed build keeps the name, so it would wedge every future trial
        # sharing that image. The state is terminal; rebuilding is all that is left.
        def discard(snapshot)
          client.snapshot.delete(snapshot)

          deadline = now + build_timeout_sec
          while find(name)
            raise InfrastructureError, "daytona: failed snapshot #{name} would not go away" if now > deadline

            sleep POLL_INTERVAL_SEC
          end
          nil
        rescue *SDK_ERRORS => e
          raise InfrastructureError, "daytona: could not remove failed snapshot #{name}: #{e.message}"
        end

        def find(name)
          with_read_retries { client.snapshot.get(name) }
        rescue *SDK_ERRORS => e
          return nil if status_code(e) == 404

          raise InfrastructureError, "daytona: could not look up snapshot #{name}: #{e.message}"
        end

        # The SDK's blocking create has no budget of its own, so
        # environment.build_timeout is enforced here or nowhere.
        def build(name)
          params = ::Daytona::CreateSnapshotParams.new(
            name: name,
            # A published reference goes in as a one-line `FROM`, not a bare name:
            # Daytona mangles a bare name's `@sha256:` pin into an invalid reference.
            image: image.built? ? ::Daytona::Image.from_dockerfile(image.dockerfile_path.to_s) : base_image,
            resources: daytona_resources
          )
          Timeout.timeout(build_timeout_sec, InfrastructureError,
                          "daytona: snapshot #{name} did not build within #{build_timeout_sec}s") do
            client.snapshot.create(params, on_logs: logger)
          end
        rescue *SDK_ERRORS => e
          unless status_code(e) == 409
            raise InfrastructureError,
                  "daytona: could not build snapshot #{name}: #{e.message}"
          end

          # Another process reached the same missing snapshot first; this trial
          # waits for its build rather than failing.
          taken = find(name)
          raise InfrastructureError, "daytona: snapshot #{name} was taken and then vanished" if taken.nil?

          await_ready(taken)
        end

        # A snapshot that exists may still be building for whoever won the race,
        # or deactivated from disuse — a weekly wave will hit that.
        def await_ready(snapshot)
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
            snapshot = find(name)
            if snapshot.nil?
              raise InfrastructureError,
                    "daytona: snapshot #{name} vanished while it was being waited on"
            end
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

        def to_gib(megabytes) = [(megabytes / 1024.0).ceil, 1].max

        def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
