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
        resources_with(memory_mb: 4096), resources_with(storage_mb: 10_240)
      ]

      names = shapes.map { snapshot_name_for(image, resources: _1) }

      assert_equal shapes.size, names.uniq.size
    end
  end

  def test_a_published_image_gets_one_snapshot_per_shape
    image = Lemans::Corpus::Task::ImageSpec.registry("ghcr.io/lemans/reference@sha256:#{"ab" * 32}")

    assert_equal snapshot_name_for(image), snapshot_name_for(image)
    assert_match(/\Alemans-[0-9a-f]{32}\z/, snapshot_name_for(image))
    refute_equal snapshot_name_for(image), snapshot_name_for(image, resources: resources_with(cpus: 4))
  end

  # The name is the content, so a build that failed under it refuses every
  # task that shares the image — on a shared-image corpus, all of them.
  def test_a_poisoned_snapshot_is_thrown_away_and_built_again
    snapshots = FakeSnapshotService.new(answers: [failed_snapshot])

    with_client(snapshots) do
      environment_for(Lemans::Corpus::Task::ImageSpec.registry("ghcr.io/lemans/reference:1")).send(:ensure_snapshot)
    end

    assert_equal [failed_snapshot.name], snapshots.deleted.map(&:name)
    assert_equal 1, snapshots.created.size
  end

  def test_it_gives_up_rather_than_build_over_a_snapshot_that_will_not_go_away
    snapshots = FakeSnapshotService.new(answers: Array.new(50, failed_snapshot))

    error = with_client(snapshots) do
      assert_raises(Lemans::InfrastructureError) do
        environment_for(Lemans::Corpus::Task::ImageSpec.registry("ghcr.io/lemans/reference:1"),
                        build_timeout_sec: 0).send(:ensure_snapshot)
      end
    end

    assert_match(/would not go away/, error.message)
    assert_empty snapshots.created
  end

  def test_an_allowlist_mixing_domains_and_ips_is_refused
    policy = Lemans::Corpus::NetworkPolicy.new(mode: :allowlist, hosts: ["openrouter.ai", "10.0.0.0/8"])
    environment = environment_for(Lemans::Corpus::Task::ImageSpec.registry("ghcr.io/lemans/reference:1"))

    assert_raises(Lemans::ConfigError) { environment.send(:network_kwargs, policy) }
  end

  # timeout = 0 is libcurl's "no timeout": one silently dropped connection
  # would park a worker thread forever, unkillable even by Thread#kill.
  def test_every_generated_client_gets_a_real_http_deadline
    [::DaytonaApiClient, ::DaytonaToolboxApiClient, ::DaytonaAnalyticsApiClient].each do |client_mod|
      assert_equal Lemans::Environments::Daytona::HTTP_TIMEOUT_SEC, client_mod::Configuration.new.timeout
    end
    assert_operator Lemans::Environments::Daytona::HTTP_TIMEOUT_SEC, :>,
                    Lemans::Environments::Daytona::SHORT_COMMAND_SEC
  end

  def test_a_snapshot_lookup_survives_a_dropped_connection
    snapshots = FlakySnapshotService.new(failures: 2, snapshot: failed_snapshot)
    environment = quiet(environment_for(Lemans::Corpus::Task::ImageSpec.registry("ghcr.io/lemans/reference:1")))

    found = with_client(snapshots) { environment.send(:find_snapshot, "any") }

    assert_equal failed_snapshot, found
    assert_equal 3, snapshots.calls
  end

  def test_a_snapshot_lookup_does_not_retry_a_missing_snapshot
    snapshots = FlakySnapshotService.new(failures: 5, snapshot: failed_snapshot, status_code: 404)
    environment = quiet(environment_for(Lemans::Corpus::Task::ImageSpec.registry("ghcr.io/lemans/reference:1")))

    found = with_client(snapshots) { environment.send(:find_snapshot, "any") }

    assert_nil found
    assert_equal 1, snapshots.calls
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

  class FakeDaytonaConfig
    attr_accessor :api_key, :jwt_token

    def read_env(_key) = nil
  end

  private

  def failed_snapshot
    @failed_snapshot ||= FailedSnapshot.new("poisoned", ::DaytonaApiClient::SnapshotState::BUILD_FAILED,
                                            "the registry blinked")
  end

  def with_client(snapshots, &)
    Lemans::Environments::Daytona.stub(:client, FakeClient.new(snapshots), &)
  end

  # Retries back off for real; the test should not.
  def quiet(environment)
    def environment.sleep(_seconds) = nil
    environment
  end

  def snapshot_name_for(image, resources: resources_with)
    environment_for(image, resources: resources).send(:snapshot_name)
  end

  def environment_for(image, resources: resources_with, build_timeout_sec: 4)
    Lemans::Environments::Daytona.new(image: image, resources: resources,
                                      network: Lemans::Corpus::NetworkPolicy.none, build_timeout_sec: build_timeout_sec)
  end

  def resources_with(cpus: 2, memory_mb: 2048, storage_mb: 5120)
    Lemans::Corpus::Bench::Resources.new(cpus: cpus, memory_mb: memory_mb, storage_mb: storage_mb)
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
    Lemans::Corpus::Task::ImageSpec.dockerfile(dir.join("Dockerfile"), slug: slug)
  end
end
