# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OracleTest < Minitest::Test
  include BenchFixture

  # The fixture task ships solve.sh, so trial-level tests cover that path;
  # this covers the bare-patch convention that keeps a bench from copying
  # the same three lines into every task.
  def test_a_bare_solution_patch_is_applied_by_the_oracle_itself
    with_solution("solution.patch" => "diff --git a/x b/x\n") do |task|
      fake = TestEnvironment.new
      oracle.run(task, fake)

      command = fake.commands.fetch(0)

      assert_includes command, "cd /app && git apply"
      assert_includes command, "/solution/solution.patch"
      assert_includes fake.uploads.map(&:last), "/solution/solution.patch"
    end
  end

  def test_a_solve_executable_wins_and_gets_its_mode_bit
    with_solution("solve" => "#!/usr/bin/env ruby\nputs :solved\n", "solution.patch" => "diff\n") do |task|
      fake = TestEnvironment.new
      oracle.run(task, fake)

      assert_equal "chmod +x /solution/solve && /solution/solve", fake.commands.fetch(0)
    end
  end

  def test_a_step_projection_hands_the_oracle_its_indexed_solution
    with_task_dir("multi") do |dir|
      dir.join("instruction.md").write("---\nmultistep: true\n---\nP.\n\n---\n\nS1.\n\n---\n\nS2.\n")
      dir.join("solution.1.patch").write("diff a\n")
      task = Lemans::TaskDefinition.load_from_directory(load_config, dir)
      fake = TestEnvironment.new

      oracle.run(task.for_step(1), fake)

      assert_includes fake.uploads.map(&:last), "/solution/solution.patch"
      assert_includes fake.commands.fetch(0), "git apply"

      error = assert_raises(Lemans::ConfigError) { oracle.run(task.for_step(2), fake) }

      assert_includes error.message, "no solution/ to run"
    end
  end

  def test_a_solution_with_neither_entrypoint_nor_patch_is_the_authors_bug
    with_solution("README.md" => "nothing runnable") do |task|
      error = assert_raises(Lemans::ConfigError) { oracle.run(task, TestEnvironment.new) }

      assert_match(/neither solve, solve.sh nor solution.patch/, error.message)
    end
  end

  FakeTask = Struct.new(:name, :solution_context, :config) do
    def solution_files
      solution_context.glob("**/*").select(&:file?).map { [ it, it.relative_path_from(solution_context).to_s ] }
    end

    def solution? = solution_files.any?

    def environment = config.environment
  end

  private

  def oracle = Lemans::Agents::Oracle.new(profile: load_config.agent)

  def with_solution(files)
    Dir.mktmpdir do |dir|
      solution = Pathname(dir).join("solution")
      solution.mkpath
      files.each { |name, content| solution.join(name).write(content) }

      yield FakeTask.new("bare-task", solution, load_config)
    end
  end
end
