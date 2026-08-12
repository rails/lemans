# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class OracleTest < Minitest::Test
  include CorpusFixture

  # The fixture task ships solve.sh, so trial-level tests cover that path;
  # this covers the bare-patch convention that keeps a corpus from copying
  # the same three lines into every task.
  def test_a_bare_solution_patch_is_applied_by_the_oracle_itself
    with_solution("solution.patch" => "diff --git a/x b/x\n") do |task, logs_dir|
      fake = FakeEnvironment.new
      Lemans::Agents::Oracle.new(profile: load_bench.agent).call(fake, task: task, logs_dir: logs_dir)

      command = fake.commands.fetch(0)

      assert_includes command, %(cd "/app" && git apply)
      assert_includes command, "/solution/solution.patch"
      assert_includes fake.uploads.map(&:last), "/solution/solution.patch"
    end
  end

  def test_a_solution_with_neither_entrypoint_nor_patch_is_the_authors_bug
    with_solution("README.md" => "nothing runnable") do |task, logs_dir|
      error = assert_raises(Lemans::ConfigError) do
        Lemans::Agents::Oracle.new(profile: load_bench.agent).call(FakeEnvironment.new, task: task, logs_dir: logs_dir)
      end

      assert_match(/neither solve.sh nor solution.patch/, error.message)
    end
  end

  FakeTask = Struct.new(:name, :solution_context, :bench) do
    def solution? = solution_context.directory?
  end

  private

  def with_solution(files)
    Dir.mktmpdir do |dir|
      solution = Pathname(dir).join("solution")
      solution.mkpath
      files.each { |name, content| solution.join(name).write(content) }

      yield FakeTask.new("bare-task", solution, load_bench), Pathname(dir)
    end
  end
end
