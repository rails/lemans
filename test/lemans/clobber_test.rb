# frozen_string_literal: true

require "test_helper"

class ClobberTest < Minitest::Test
  def store_result(store, task:, age: 0, outcome: :completed, reward: 1.0)
    result = Lemans::Result.new(task:, agent: "oracle", model: "m/model-a")
    finished = Time.now.utc - age
    result.phase_started(:agent, finished - 10)
    result.phase_finished(:agent, finished)
    result.completed!(outcome)
    result.graded!(reward)
    store.save(result)
    result
  end

  def with_store
    Dir.mktmpdir { yield Lemans::Stores::FS.new(it), Pathname(it) }
  end

  def clobber(store, **) = Lemans::Clobber.new(store, **)

  def test_no_filters_selects_every_result
    with_store do |store, runs|
      store_result(store, task: "hello-world")
      store_result(store, task: "ar-announce-once")
      runs.join("notes.txt").write("keep me")

      deleted = clobber(store).execute!

      assert_equal 2, deleted.size
      # A stray file is not lemans' to delete, even under "delete everything";
      # the emptied model directories are.
      assert_equal(%w[notes.txt], runs.children.map { it.basename.to_s })
    end
  end

  def test_task_filter_takes_several_names_and_leaves_the_rest
    with_store do |store, _runs|
      doomed = [store_result(store, task: "hello-world"), store_result(store, task: "ar-announce-once")]
      spared = store_result(store, task: "ac-throttle-search")

      deleted = clobber(store, tasks: %w[hello-world ar-announce-once]).execute!

      assert_equal doomed.map(&:id).sort, deleted.map(&:id).sort
      assert_equal [spared.id], store.fetch.map(&:id)
    end
  end

  def test_older_than_measures_the_recorded_finish
    with_store do |store, _runs|
      old = store_result(store, task: "hello-world", age: 3600)
      fresh = store_result(store, task: "hello-world")

      assert_equal [old.id], clobber(store, ttl: "10m").execute!.map(&:id)
      assert_equal [fresh.id], store.fetch.map(&:id)
    end
  end

  def test_a_ttl_that_does_not_parse_is_refused
    with_store do |store, _runs|
      assert_raises(Lemans::ConfigError) { clobber(store, ttl: "soon") }
    end
  end

  def test_the_invalid_filter_spares_everything_that_scored_and_claims_the_unreadable
    with_store do |store, runs|
      scored = store_result(store, task: "hello-world")
      store_result(store, task: "ar-announce-once", outcome: :environment_error, reward: nil)
      truncated = runs.join("model-a", "ac-throttle-search__abc1234")
      truncated.mkpath
      truncated.join("result.json").write("{ half a resu")

      deleted = clobber(store, invalid: true).execute!

      assert_equal 2, deleted.size
      assert_includes deleted.map(&:id), "ac-throttle-search__abc1234"
      assert_equal [scored.id], store.fetch.map(&:id)
    end
  end

  def test_execute_deletes_what_matches_showed_not_a_fresh_selection
    with_store do |store, _runs|
      store_result(store, task: "hello-world")
      doomed = clobber(store)

      assert_equal 1, doomed.matches.size

      latecomer = store_result(store, task: "hello-world")
      doomed.execute!

      assert_equal [latecomer.id], store.fetch.map(&:id)
    end
  end

  def test_a_missing_runs_directory_is_empty_rather_than_an_error
    assert_empty Lemans::Clobber.new(Lemans::Stores::FS.new("does/not/exist")).matches
  end
end
