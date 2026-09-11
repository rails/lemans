# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The fakes below lean on the SDK's own error and state constants, which
# arrive with the backend — loaded here so test order cannot matter.
require "daytona"

class DaytonaEnvironmentTest < Minitest::Test
  # A snapshot is reused by name, so the name is the isolation boundary. These
  # never reach Daytona: what is being checked is what would be asked for.
  def test_two_different_build_contexts_get_two_snapshots
    in_root do
      refute_equal snapshot_name_for(context_with({ "app.rb" => "task one" })),
                   snapshot_name_for(context_with({ "app.rb" => "task two" }))
    end
  end

  def test_two_tasks_sharing_a_context_byte_for_byte_share_a_snapshot
    in_root do
      one = context_with({ "app.rb" => "shared" }, slug: "ar-tenant-isolation")
      other = context_with({ "app.rb" => "shared" }, slug: "ac-flooded-search")

      assert_equal snapshot_name_for(one), snapshot_name_for(other)
    end
  end

  # A sandbox inherits its snapshot's resources, so two shapes over one image
  # must not share a snapshot.
  def test_every_resource_dimension_is_part_of_the_name
    in_root do
      image = context_with({ "app.rb" => "shared" })
      shapes = [
        resources_with, resources_with(cpus: 8),
        resources_with(memory: 4096), resources_with(storage: 10_240)
      ]

      names = shapes.map { snapshot_name_for(image, resources: it) }

      assert_equal shapes.size, names.uniq.size
    end
  end

  def test_a_published_image_gets_one_snapshot_per_shape
    image = Lemans::Config::ImageSpec.registry("ghcr.io/lemans/reference@sha256:#{"ab" * 32}")

    assert_equal snapshot_name_for(image), snapshot_name_for(image)
    assert_match(/\Alemans-[0-9a-f]{32}\z/, snapshot_name_for(image))
    refute_equal snapshot_name_for(image), snapshot_name_for(image, resources: resources_with(cpus: 4))
  end

  # The name is the content, so a build that failed under it refuses every
  # task that shares the image — on a shared-image bench, all of them.
  def test_a_poisoned_snapshot_is_thrown_away_and_built_again
    snapshots = FakeSnapshotService.new(answers: [ failed_snapshot ])

    store_for(reference_image, snapshots: snapshots).call

    assert_equal [ failed_snapshot.name ], snapshots.deleted.map(&:name)
    assert_equal 1, snapshots.created.size
  end

  def test_it_gives_up_rather_than_build_over_a_snapshot_that_will_not_go_away
    snapshots = FakeSnapshotService.new(answers: Array.new(50, failed_snapshot))

    error = assert_raises(Lemans::InfrastructureError) do
      store_for(reference_image, snapshots: snapshots, build_timeout: 0).call
    end

    assert_match(/would not go away/, error.message)
    assert_empty snapshots.created
  end

  def test_an_allowlist_mixing_domains_and_ips_is_refused
    policy = Lemans::Config::NetworkPolicy.new("allowlist", [ "openrouter.ai", "10.0.0.0/8" ])
    environment = environment_for(reference_image)

    assert_raises(Lemans::ConfigError) { environment.send(:network_kwargs, policy) }
  end

  # A libcurl GC race segfaults the VM under concurrent transfers; the pure-Ruby
  # reroute is what lets uploads and downloads run unthrottled.
  def test_file_transfers_ride_faraday_not_libcurl
    assert_includes ::Daytona::FileTransfer.singleton_class.ancestors,
                    Lemans::Environments::Daytona::FaradayTransfer::Transfers
  end

  # timeout = 0 is libcurl's "no timeout": one silently dropped connection
  # would park a worker thread forever, unkillable even by Thread#kill.
  def test_every_generated_client_gets_a_real_http_deadline
    tweaks = Lemans::Environments::Daytona::SDKTweaks
    tweaks::GENERATED_CLIENTS.each do |client_mod|
      assert_equal tweaks::HTTP_TIMEOUT_SEC, client_mod::Configuration.new.timeout
    end
    assert_operator tweaks::HTTP_TIMEOUT_SEC, :>, Lemans::Environments::Daytona::Shell::SHORT_COMMAND_SEC
  end

  def test_a_deliberately_configured_deadline_wins_over_the_default
    config = ::DaytonaApiClient::Configuration.new
    config.timeout = 7

    assert_equal 7, config.timeout
  end

  def test_an_explicit_nil_deadline_is_respected_not_crashed_on
    config = ::DaytonaApiClient::Configuration.new
    config.timeout = nil

    assert_nil config.timeout
  end

  def test_a_snapshot_lookup_survives_a_dropped_connection
    snapshots = FlakySnapshotService.new(failures: 2, snapshot: failed_snapshot)

    found = store_for(reference_image, snapshots: snapshots).send(:find, "any")

    assert_equal failed_snapshot, found
    assert_equal 3, snapshots.calls
  end

  def test_a_snapshot_lookup_retries_a_daemon_timeout
    snapshots = FlakySnapshotService.new(failures: 2, snapshot: failed_snapshot, status_code: 408)

    found = store_for(reference_image, snapshots: snapshots).send(:find, "any")

    assert_equal failed_snapshot, found
    assert_equal 3, snapshots.calls
  end

  def test_a_snapshot_lookup_does_not_retry_a_missing_snapshot
    snapshots = FlakySnapshotService.new(failures: 5, snapshot: failed_snapshot, status_code: 404)

    found = store_for(reference_image, snapshots: snapshots).send(:find, "any")

    assert_nil found
    assert_equal 1, snapshots.calls
  end

  def test_a_snapshot_lookup_does_not_retry_a_caller_mistake
    snapshots = FlakySnapshotService.new(failures: 5, snapshot: failed_snapshot, status_code: 403)

    assert_raises(Lemans::InfrastructureError) { store_for(reference_image, snapshots: snapshots).send(:find, "any") }
    assert_equal 1, snapshots.calls
  end

  # client.create succeeded, the session did not: without the rollback the
  # sandbox would bill until its TTL, unreachable by the trial's ensure.
  def test_a_sandbox_whose_start_fails_partway_is_deleted_not_leaked
    sandbox = StillbornSandbox.new
    client = FakeStartClient.new(FlakySnapshotService.new(failures: 0, snapshot: active_snapshot), sandbox)
    environment = environment_for(reference_image)

    error = Lemans::Environments::Daytona.stub(:client, client) do
      assert_raises(Lemans::InfrastructureError) { environment.start }
    end

    assert_match(/could not start sandbox/, error.message)
    assert sandbox.deleted
  end

  # The SDK gives a sandbox one fixed minute to start; under load Daytona
  # needs longer, and the sandbox it did make still carries the trial's labels.
  def test_a_stalled_sandbox_is_adopted_or_reaped_before_creation_is_retried
    stalled = ScriptedSandbox.new("sb-slow", state: "starting")
    client = ScriptedClient.new(failures: 1, sandbox: ScriptedSandbox.new("sb-fresh"), half_created: [ stalled ])
    environment = environment_for(reference_image, labels: TRIAL_LABELS)
    start(environment, client)

    assert_same stalled, environment.sandbox
    assert_equal 1, client.creates
    assert_equal [ TRIAL_LABELS ], client.queried_labels
    refute stalled.deleted

    stuck = ScriptedSandbox.new("sb-stuck", state: "creating", starts: false)
    fresh = ScriptedSandbox.new("sb-fresh")
    client = ScriptedClient.new(failures: 1, sandbox: fresh, half_created: [ stuck ])
    log = []
    environment = environment_for(reference_image, labels: TRIAL_LABELS, logger: ->(line) { log << line })
    start(environment, client)

    assert_same fresh, environment.sandbox
    assert_equal 2, client.creates
    assert stuck.deleted
    assert_match(/attempt 2\/3/, log.join)
  end

  # The last attempt's leftover has no retry to reap it, so giving up must.
  def test_creation_gives_up_after_three_attempts_and_reaps_the_last_leftover
    leftover = ScriptedSandbox.new("sb-leftover", state: "error")
    client = ScriptedClient.new(failures: 10, sandbox: nil, half_created: [ leftover ], appears_at: 3)
    environment = environment_for(reference_image, labels: TRIAL_LABELS)

    error = assert_raises(Lemans::InfrastructureError) { start(environment, client) }

    assert_match(/could not start sandbox/, error.message)
    assert_equal 3, client.creates
    assert leftover.deleted
  end

  # A repeat while the original may still be running would double up: so
  # would one made blind, without labels or with the listing down. A refused
  # snapshot or key fails the same way every time.
  def test_creation_is_not_retried_unless_the_half_made_sandbox_is_accounted_for
    stuck = ScriptedSandbox.new("sb-stuck", state: "error", deletable: false)
    client = ScriptedClient.new(failures: 10, sandbox: nil, half_created: [ stuck ])
    error = assert_raises(Lemans::InfrastructureError) { start(environment_for(reference_image, labels: TRIAL_LABELS), client) }

    assert_includes error.message, "sb-stuck may still be running"
    assert_equal 1, client.creates

    twins = [ ScriptedSandbox.new("sb-one", state: "error"), ScriptedSandbox.new("sb-two", state: "error") ]
    client = ScriptedClient.new(failures: 10, sandbox: nil, half_created: twins)
    error = assert_raises(Lemans::InfrastructureError) { start(environment_for(reference_image, labels: TRIAL_LABELS), client) }

    assert_includes error.message, "sb-one, sb-two all carry"
    assert_equal 1, client.creates
    refute twins.any?(&:deleted)

    client = ScriptedClient.new(failures: 10, sandbox: nil, half_created: [], lists: false)
    error = assert_raises(Lemans::InfrastructureError) { start(environment_for(reference_image, labels: TRIAL_LABELS), client) }

    assert_includes error.message, "listing them failed"
    assert_equal 1, client.creates

    client = ScriptedClient.new(failures: 10, sandbox: nil, half_created: [])
    assert_raises(Lemans::InfrastructureError) { start(environment_for(reference_image), client) }

    assert_equal 1, client.creates
    assert_empty client.queried_labels

    client = ScriptedClient.new(failures: 10, sandbox: nil, half_created: [], status_code: 404)
    assert_raises(Lemans::InfrastructureError) { start(environment_for(reference_image, labels: TRIAL_LABELS), client) }

    assert_equal 1, client.creates
    assert_empty client.queried_labels
  end

  # ttl_minutes is a hard lifetime cap: a sandbox reaped under a legitimate
  # long run fails its next exec with a vague "is the Sandbox started?".
  def test_the_sandbox_lives_as_long_as_the_trial_asked_for
    assert_equal 90, environment_for(reference_image, ttl: 90 * 60).send(:ttl_minutes)
    assert_equal 61, environment_for(reference_image, ttl: 3601).send(:ttl_minutes)
    assert_equal 60, environment_for(reference_image).send(:ttl_minutes)
  end

  def test_an_exec_failing_past_the_ttl_says_so
    environment = environment_for(reference_image, ttl: 60)
    environment.instance_variable_set(:@shell, BrokenShell.new)
    environment.instance_variable_set(:@started_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))

    error = assert_raises(Lemans::InfrastructureError) { environment.exec("true") }

    assert_equal "daytona: exec failed: no IP address found", error.message

    environment.instance_variable_set(:@started_at, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 61)
    error = assert_raises(Lemans::InfrastructureError) { environment.exec("true") }

    assert_equal "daytona: exec failed after the sandbox's 1m TTL expired (raise environment.sandbox_ttl): no IP address found",
                 error.message
  end

  def test_it_says_both_names_it_accepts_when_there_are_no_credentials
    config = FakeDaytonaConfig.new

    error = ::Daytona::Config.stub(:new, config) do
      assert_raises(Lemans::ConfigError) { Lemans::Environments::Daytona.credentials }
    end

    assert_match(/DAYTONA_API_KEY or DAYTONA_TOKEN/, error.message)
  end

  # --- fakes ---

  FailedSnapshot = Struct.new(:name, :state, :error_reason)

  TRIAL_LABELS = { "lemans.trial" => "t1" }.freeze

  class FakeSnapshotService
    attr_reader :deleted, :created

    def initialize(answers:)
      @answers = answers.dup
      @deleted = []
      @created = []
    end

    def get(_name)
      @answers.shift or raise ::Daytona::Sdk::Error.new("no such snapshot", status_code: 404)
    end

    def delete(snapshot) = @deleted << snapshot

    def create(params, on_logs: nil) = @created << params
  end

  # A connection that drops N times before the service answers.
  class FlakySnapshotService
    attr_reader :calls

    def initialize(failures:, snapshot:, status_code: nil)
      @failures = failures
      @snapshot = snapshot
      @status_code = status_code
      @calls = 0
    end

    def get(_name)
      @calls += 1
      raise ::Daytona::Sdk::Error.new("Connection timed out", status_code: @status_code) if @calls <= @failures

      @snapshot
    end
  end

  FakeClient = Struct.new(:snapshot)

  # create succeeds, the first session does not — the partial-start case.
  class StillbornSandbox
    attr_reader :deleted

    def id = "sb-stillborn"

    def process
      @process ||= Object.new.tap do |process|
        def process.create_session(_id) = raise ::Daytona::Sdk::Error, "the toolbox is down"
      end
    end

    def delete(wait: false) = @deleted = true
  end

  class BrokenShell
    def exec(_command, timeout: nil, env: {}) = raise ::Daytona::Sdk::Error, "no IP address found"
  end

  FakeStartClient = Struct.new(:snapshot, :sandbox) do
    def create(_params, on_snapshot_create_logs: nil) = sandbox
  end

  # A sandbox Daytona accepted but has not started: `state` is what a listing
  # reports, `starts` whether waiting on it pays off.
  class ScriptedSandbox
    attr_reader :id, :state, :deleted

    def initialize(id, state: "started", starts: true, deletable: true)
      @id = id
      @state = state
      @starts = starts
      @deletable = deletable
      @deleted = false
    end

    # Like the SDK: a sandbox already in an error state fails the wait at once.
    def wait_for_sandbox_start(_timeout)
      raise ::Daytona::Sdk::Error, "Sandbox #{id} is in #{state} state" if %w[error build_failed].include?(@state)
      raise ::Daytona::Sdk::TimeoutError, "Sandbox #{id} failed to start within the 180 seconds timeout period" unless @starts

      @state = "started"
    end

    def delete(wait: false)
      raise ::Daytona::Sdk::Error, "Failed to delete sandbox #{id}" unless @deletable

      @deleted = true
    end

    def process
      @process ||= Object.new.tap do |process|
        def process.create_session(_id) = nil
      end
    end
  end

  # create fails N times, then answers; list answers with the half-created
  # sandboxes (from the `appears_at`-th listing on) and records what it was
  # asked for.
  class ScriptedClient
    attr_reader :creates, :queried_labels

    def initialize(failures:, sandbox:, half_created:, status_code: nil, appears_at: 1, lists: true)
      @failures = failures
      @sandbox = sandbox
      @half_created = half_created
      @status_code = status_code
      @appears_at = appears_at
      @lists = lists
      @creates = 0
      @listings = 0
      @queried_labels = []
    end

    def snapshot = FlakySnapshotService.new(failures: 0, snapshot: FailedSnapshot.new("ready", ::DaytonaApiClient::SnapshotState::ACTIVE, nil))

    def create(_params, on_snapshot_create_logs: nil)
      @creates += 1
      raise ::Daytona::Sdk::Error.new("Failed to create sandbox", status_code: @status_code) if @status_code && @creates <= @failures
      raise ::Daytona::Sdk::TimeoutError, "Sandbox sb-slow failed to start within the 0.001 seconds timeout period" if @creates <= @failures

      @sandbox
    end

    def list(query)
      @queried_labels << query.labels
      raise ::Daytona::Sdk::Error, "Failed to list sandboxes" unless @lists

      @listings += 1
      return [].each if @listings < @appears_at

      @half_created.reject(&:deleted).each
    end
  end

  class FakeDaytonaConfig
    attr_accessor :api_key, :jwt_token

    def read_env(_key) = nil
  end

  private

  def failed_snapshot
    @failed_snapshot ||= FailedSnapshot.new("poisoned", ::DaytonaApiClient::SnapshotState::BUILD_FAILED,
                                            "the registry blinked")
  end

  def active_snapshot
    @active_snapshot ||= FailedSnapshot.new("ready", ::DaytonaApiClient::SnapshotState::ACTIVE, nil)
  end

  def reference_image
    Lemans::Config::ImageSpec.registry("ghcr.io/lemans/reference:1")
  end

  def store_for(image, snapshots: nil, resources: resources_with, build_timeout: 4)
    store = Lemans::Environments::Daytona::SnapshotStore.new(
      client: snapshots && FakeClient.new(snapshots),
      image: image, resources: resources, build_timeout: build_timeout
    )
    quiet(store)
  end

  # Polls and retries back off for real; the tests should not.
  def quiet(store)
    def store.sleep(_seconds) = nil
    store
  end

  def snapshot_name_for(image, resources: resources_with)
    store_for(image, resources: resources).name
  end

  def environment_for(image, resources: resources_with, build_timeout: 4, ttl: 3600, labels: {}, logger: nil)
    environment = Lemans::Environments::Daytona.new(image: image, resources: resources, ttl: ttl, labels: labels, logger: logger,
                                                    network: Lemans::Config::NetworkPolicy.new("none"), build_timeout: build_timeout)
    quiet(environment)
  end

  def start(environment, client)
    Lemans::Environments::Daytona.stub(:client, client) { environment.start }
  end

  def resources_with(cpus: 2, memory: 2048, storage: 5120)
    Lemans::Config::Environment::Resources.new(cpus: cpus, memory: memory, storage: storage)
  end

  def in_root(&)
    Dir.mktmpdir do |root|
      @tmp_root = root
      yield
    end
  end

  def context_with(files, slug: "a-task")
    dir = Pathname(Dir.mktmpdir(nil, @tmp_root))
    dir.join("Dockerfile").write("FROM ruby:3.4-slim\nCOPY . /app\n")
    files.each { |path, content| dir.join(path).write(content) }
    Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile"), slug: slug)
  end
end
