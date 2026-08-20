# frozen_string_literal: true

require "test_helper"

class TaskDefinitionTest < Minitest::Test
  include BenchFixture

  def load_task(dir) = Lemans::TaskDefinition.load_from_directory(Lemans::Config.new, dir)

  def test_load
    task = Lemans::TaskDefinition.load_from_directory(load_config, BenchFixture::ROOT.join("tasks/hello-world"))

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

  def test_setup_projection_appends_the_seed
    with_task_dir("seeded") do |dir|
      dir.join("environment.patch").write("diff --git a/x b/x\n")
      task = load_task(dir)

      assert_predicate task, :seed?
      assert_equal ["environment.patch"], task.setup.files.map(&:last)
    end
  end

  def test_task_sections_extend_the_bench_ones_without_touching_them
    with_task_dir("custom") do |dir|
      dir.join("instruction.md").write(<<~MD)
        ---
        setup:
          commands: [make prep]
          files: [tests/test.sh]
        restore: [tests]
        verifier:
          setup: [make verify-prep]
        ---
        Go.
      MD
      task = load_task(dir)

      assert_includes task.setup.commands, "make prep"
      assert_includes task.setup.files.map(&:last), "tests/test.sh"
      assert_equal ["tests"], task.verifier.restore_paths
      assert_equal ["make verify-prep"], task.verifier.setup.commands
      assert_same task.config.environment, task.environment

      assert_empty task.config.setup.commands
      assert_empty task.config.verifier.restore_paths
      assert_predicate task.config.verifier.setup, :empty?
    end
  end

  def test_a_task_cannot_override_the_frozen_profile
    with_task_dir("frozen") do |dir|
      dir.join("instruction.md").write("---\noverrides: { cpus: 8 }\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "cannot override the frozen profile (cpus)"
    end
  end

  def test_a_task_may_only_override_verifier_setup
    with_task_dir("grabby") do |dir|
      dir.join("instruction.md").write("---\nverifier:\n  command: bash /cheat.sh\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "verifier.command"
    end
  end

  def test_a_task_cannot_shadow_a_bench_setup_file
    with_task_dir("shadowing") do |dir|
      config = Lemans::Config.new
      config.setup.files = [[BenchFixture::ROOT.join("bench.yml"), "tests/test.sh"]]
      dir.join("instruction.md").write("---\nsetup:\n  files: [tests/test.sh]\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { Lemans::TaskDefinition.load_from_directory(config, dir) }

      assert_includes error.message, "already ships"
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
