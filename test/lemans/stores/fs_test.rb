# frozen_string_literal: true

require "test_helper"
require "tempfile"

class StoresFSTest < Minitest::Test
  def build_result(task: "hello-world", agent: "oracle", model: "m/model-a", tags: [])
    result = Lemans::Result.new(task:, agent:, model:)
    result.tags = tags
    result.completed!(:completed, Lemans::Result::Usage.zero).graded!(1.0)
  end

  def with_store
    Dir.mktmpdir { yield Lemans::Stores::FS.new(it) }
  end

  def test_save_and_fetch_round_trip
    with_store do |store|
      saved = build_result
      store.save(saved)
      fetched = store.fetch

      assert_equal [ saved.id ], fetched.map(&:id)
      assert_equal :completed, fetched.first.status
      assert_in_delta 1.0, fetched.first.reward
    end
  end

  def test_query_filters_in_memory
    with_store do |store|
      store.save(build_result(task: "a", tags: %w[infra]))
      store.save(build_result(task: "b", model: "m/model-b"))
      store.save(build_result(task: "c", agent: "nop"))

      assert_equal %w[a], store.query(task: %w[a]).map(&:task)
      assert_equal %w[a], store.query(tags: %w[infra]).map(&:task)
      assert_equal %w[b], store.query(model: "m/model-b").map(&:task)
      assert_equal %w[c], store.query(agent: "nop").map(&:task)
      assert_equal 3, store.query.size
    end
  end

  def test_an_effort_suffix_becomes_a_folder_dash
    with_store do |store|
      saved = build_result(model: "openrouter/openai/gpt-5.6-luna#xhigh")
      store.save(saved)

      assert store.send(:root).join("gpt-5.6-luna-xhigh", saved.id, "result.json").file?
      assert_equal "openrouter/openai/gpt-5.6-luna#xhigh", store.fetch.first.model
    end
  end

  def test_an_unreadable_result_is_skipped
    with_store do |store|
      store.save(build_result)
      truncated = store.send(:root).join("model-a", "broken")
      truncated.mkpath
      truncated.join("result.json").write("{ truncated")

      assert_equal 1, store.fetch.size
    end
  end

  def test_save_artifact_writes_and_refuses_collisions
    with_store do |store|
      result = build_result
      store.save(result)

      path = store.save_artifact(result, "the checks ran", path: "checks.txt")

      assert_equal "the checks ran", path.read
      _, err = capture_io { store.save_artifact(result, "again", path: "checks.txt") }

      assert_includes err, "collides"
      assert_equal "the checks ran", path.read
    end
  end

  def test_secrets_are_filtered_from_persisted_files
    Dir.mktmpdir do |dir|
      store = Lemans::Stores::FS.new(dir, filterer: Lemans::SecretsFilter.new([ "super-secret-token" ]))
      result = build_result.failed!(:agent_error, "401 unauthorized: super-secret-token")
      store.save(result)
      saved = store.send(:result_dir, result).join("result.json").read

      refute_includes saved, "super-secret-token"
      assert_includes saved, "<filtered>"

      artifact = store.save_artifact(result, "token=super-secret-token", path: "agent.log")

      assert_equal "token=<filtered>", artifact.read

      source = Tempfile.new
      source.write("--- a\n+++ b\n+key = \"super-secret-token\"\n")
      source.rewind
      patch = store.save_artifact(result, source, path: "patch.diff")

      assert_equal "--- a\n+++ b\n+key = \"<filtered>\"\n", patch.read
    end
  end
end
