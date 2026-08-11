# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class ClobberTest < Minitest::Test
  def test_no_filters_selects_every_trial_directory
    in_runs_dir do |runs|
      trial_dir(runs, "hello-world")
      trial_dir(runs, "ar-announce-once")

      deleted = clobber(runs).call

      assert_equal 2, deleted.size
      assert_empty runs.children
    end
  end

  # A stray file or a directory lemans did not name is not lemans' to delete,
  # even under "delete everything".
  def test_only_trial_shaped_entries_are_touched
    in_runs_dir do |runs|
      trial_dir(runs, "hello-world")
      runs.join("notes.txt").write("keep me")
      FileUtils.mkdir_p(runs.join("not-a-trial"))

      clobber(runs).call

      assert_equal %w[not-a-trial notes.txt], runs.children.map { _1.basename.to_s }.sort
    end
  end

  def test_task_filter_takes_several_names_and_leaves_the_rest
    in_runs_dir do |runs|
      doomed = [trial_dir(runs, "hello-world"), trial_dir(runs, "ar-announce-once")]
      spared = trial_dir(runs, "ac-throttle-search")

      deleted = clobber(runs, tasks: %w[hello-world ar-announce-once]).call

      assert_equal doomed.sort, deleted.sort
      assert_equal [spared], runs.children
    end
  end

  # The task name is everything before the final "__<id>", so a task whose
  # own name contains underscores still filters correctly.
  def test_a_task_name_is_everything_before_the_trial_suffix
    in_runs_dir do |runs|
      doomed = trial_dir(runs, "sup_legacy__conversions")

      assert_equal [doomed], clobber(runs, tasks: %w[sup_legacy__conversions]).call
    end
  end

  def test_older_than_measures_the_directory_mtime
    in_runs_dir do |runs|
      old = trial_dir(runs, "hello-world", age_sec: 3600)
      fresh = trial_dir(runs, "hello-world")

      assert_equal [old], clobber(runs, ttl_sec: 600).call
      assert_equal [fresh], runs.children
    end
  end

  def test_filters_compose
    in_runs_dir do |runs|
      doomed = trial_dir(runs, "hello-world", age_sec: 3600)
      trial_dir(runs, "hello-world")                           # right task, too fresh
      trial_dir(runs, "ar-announce-once", age_sec: 3600)       # old enough, wrong task

      assert_equal [doomed], clobber(runs, tasks: %w[hello-world], ttl_sec: 600).call
    end
  end

  # What the caller was shown and what `call` deletes must be the same list,
  # even if a trial lands between the two.
  def test_call_deletes_what_matches_showed_not_a_fresh_selection
    in_runs_dir do |runs|
      trial_dir(runs, "hello-world")
      doomed = clobber(runs)

      assert_equal 1, doomed.matches.size

      latecomer = trial_dir(runs, "hello-world")
      doomed.call

      assert_equal [latecomer], runs.children
    end
  end

  def test_a_missing_runs_directory_is_empty_rather_than_an_error
    assert_empty Lemans::Clobber.new(runs_dir: "does/not/exist").matches
  end

  private

  def clobber(runs, tasks: [], ttl_sec: nil)
    Lemans::Clobber.new(runs_dir: runs, tasks: tasks, ttl_sec: ttl_sec)
  end

  def in_runs_dir(&)
    Dir.mktmpdir { |dir| yield Pathname(dir) }
  end

  def trial_dir(runs, task, age_sec: 0)
    dir = runs.join("#{task}__#{SecureRandom.alphanumeric(7)}")
    FileUtils.mkdir_p(dir)
    dir.join("result.json").write("{}")
    FileUtils.touch(dir, mtime: Time.now - age_sec) if age_sec.positive?
    dir
  end
end
