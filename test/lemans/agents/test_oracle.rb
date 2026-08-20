# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OracleTest < Minitest::Test
  include BenchFixture

  # The fixture task ships solve.sh, so trial-level tests cover that path;
  # this covers the bare-patch convention that keeps a bench from copying
  # the same three lines into every task.
  def test_a_bare_solution_patch_is_applied_by_the_oracle_itself
    with_solution("solution.patch" => "diff --git a/x b/x\n") do |task, logs_dir|
      fake = FakeEnvironment.new
      Lemans::Agents::Oracle.new(profile: load_config.agent).call(fake, task: task, logs_dir: logs_dir)

      command = fake.commands.fetch(0)

      assert_includes command, "cd /app && git apply"
      assert_includes command, "/solution/solution.patch"
      assert_includes fake.uploads.map(&:last), "/solution/solution.patch"
    end
  end

  def test_a_solve_executable_wins_and_gets_its_mode_bit
    with_solution("solve" => "#!/usr/bin/env ruby\nputs :solved\n", "solution.patch" => "diff\n") do |task, logs_dir|
      fake = FakeEnvironment.new
      Lemans::Agents::Oracle.new(profile: load_config.agent).call(fake, task: task, logs_dir: logs_dir)

      assert_equal "chmod +x /solution/solve && /solution/solve", fake.commands.fetch(0)
    end
  end

  def test_a_solution_with_neither_entrypoint_nor_patch_is_the_authors_bug
    with_solution("README.md" => "nothing runnable") do |task, logs_dir|
      error = assert_raises(Lemans::ConfigError) do
        Lemans::Agents::Oracle.new(profile: load_config.agent).call(FakeEnvironment.new, task: task, logs_dir: logs_dir)
      end

      assert_match(/neither solve, solve.sh nor solution.patch/, error.message)
    end
  end

  FakeTask = Struct.new(:name, :solution_context, :config) do
    def solution_files
      solution_context.glob("**/*").select(&:file?).map { [_1, _1.relative_path_from(solution_context).to_s] }
    end

    def solution? = solution_files.any?
  end

  private

  def with_solution(files)
    Dir.mktmpdir do |dir|
      solution = Pathname(dir).join("solution")
      solution.mkpath
      files.each { |name, content| solution.join(name).write(content) }

      yield FakeTask.new("bare-task", solution, load_config), Pathname(dir)
    end
  end
end
