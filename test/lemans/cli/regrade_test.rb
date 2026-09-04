# frozen_string_literal: true

require "test_helper"
require "json"
require "yaml"

class CLIRegradeTest < Minitest::Test
  include BenchFixture

  TEST_FILE = <<~RUBY
    require "minitest/autorun"

    LemansReport.base_credit = 0.6

    class GradedTest < Minitest::Test
      def test_required = assert true

      test "nice to have" do
        allow_failure(points: 2) { assert true }
      end
    end
  RUBY

  def test_a_run_is_regraded_from_its_checks_after_a_test_becomes_extra
    with_task_dir("graded") do |task_dir|
      task_dir.join("verification_test.rb").write(TEST_FILE)
      bench = task_dir.parent
      contents = YAML.safe_load_file(BenchFixture::ROOT.join("bench.yml"), aliases: true)
      contents["tasks"] = bench.to_s
      bench.join("bench.yml").write(YAML.dump(contents))

      Dir.mktmpdir do |runs|
        store = Lemans::Stores::FS.new(runs)
        result = Lemans::Result.new(task: "graded", agent: "miniswen", model: "m/model-a", id: "graded__aaaaaaa")
        result.completed!(:completed, Lemans::Result::Usage.zero).graded!(0.0)
        store.save(result)
        store.save_artifact(result, JSON.generate(
          checks: { "GradedTest#test_required" => "pass", "GradedTest#test_nice_to_have" => "fail" },
          failures: [ "GradedTest#test_nice_to_have" ], allowed_failures: {}
        ), path: "checks.json")

        out, = capture_io do
          Lemans::CLI.start(%W[regrade --bench #{bench} --task graded --runs-dir #{runs}])
        end

        assert_includes out, "graded__aaaaaaa  reward 0.0 -> 1.0  credit 0.0 -> 0.6"
        assert_includes out, "graded: 1 re-graded, 0 skipped"
      assert_includes out, "1 trials: 1 scored, 0 invalid, 1 solved (100%)"

        regraded = store.query(task: "graded").first

        assert_in_delta 1.0, regraded.reward
        assert_in_delta 0.6, regraded.credit

        checks = JSON.parse(store.read_artifact(regraded, "checks.json"))

        assert_equal "fail (allowed)", checks["checks"]["GradedTest#test_nice_to_have"]
        assert_empty checks["failures"]
        assert_equal({ "base_credit" => 0.6, "points" => { "GradedTest#test_nice_to_have" => 2 } }, checks["grading"])

        # Nothing changed since: the files stay untouched.
        again, = capture_io { Lemans::CLI.start(%W[regrade --bench #{bench} --task graded --runs-dir #{runs}]) }

        assert_includes again, "graded__aaaaaaa  unchanged"
        assert_includes again, "graded: 0 re-graded, 1 skipped"
      end
    end
  end
end
