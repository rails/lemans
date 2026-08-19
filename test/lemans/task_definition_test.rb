# frozen_string_literal: true

require "test_helper"

class TaskDefinitionTest < Minitest::Test
  include BenchFixture

  def load_task(dir) = Lemans::TaskDefinition.load_from_directory(Lemans::Config.new, dir)

  def test_load
    task = load_task(BenchFixture::ROOT.join("tasks/hello-world"))

    assert_equal "hello-world", task.name
    assert_equal "Prove the harness end to end", task.description
    assert_equal :easy, task.difficulty
    assert_equal ["infrastructure"], task.tags
    assert_equal "infrastructure", task.metadata["category"]
    assert_match(/\A[0-9a-f]{16}\z/, task.digest)
    assert_includes task.instruction, "hello.txt"
    refute_includes task.instruction, "---"
  end

  def test_frontmatter_defaults
    with_task_dir("minimal") do |dir|
      dir.join("instruction.md").write("Fix it.\n")
      task = load_task(dir)

      assert_equal "minimal", task.name
      assert_equal :easy, task.difficulty
      assert_empty task.tags
      assert_empty task.metadata
    end
  end

  def test_unclosed_frontmatter
    with_task_dir("broken") do |dir|
      dir.join("instruction.md").write("---\ndescription: broken\nFix it.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "never closes"
    end
  end

  def test_missing_instruction
    with_task_dir("bare") do |dir|
      dir.join("instruction.md").delete

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "instruction.md is required"
    end
  end
end
