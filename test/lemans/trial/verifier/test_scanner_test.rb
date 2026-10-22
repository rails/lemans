# frozen_string_literal: true

require "test_helper"

class TrialVerifierTestScannerTest < Minitest::Test
  def scan(files)
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      files.each do |name, source|
        root.join(name).dirname.mkpath
        root.join(name).write(source)
      end
      scanner = Lemans::Trial::Verifier::TestScanner.new(root)
      scanner.scan(root.join("verification_test.rb"))
      yield scanner, root
    end
  end

  def test_checks_points_and_requires
    scan(
      "verification_test.rb" => <<~RUBY,
        require "minitest/autorun"
        require "suites/extra"
        require_relative "suites/extra"

        LemansReport.base_credit = 0.6

        class RequiredTest < Minitest::Test
          def test_required = assert true
          def test_lines(command) = command
        end
      RUBY
      "suites/extra.rb" => <<~RUBY
        class ExtraTest < Minitest::Test
          test "timestamps" do
            allow_failure(points: 3) { assert true }
          end
        end
      RUBY
    ) do |scanner|
      assert_equal %w[ExtraTest#test_timestamps RequiredTest#test_required], scanner.tests
      assert_equal({ "ExtraTest#test_timestamps" => 3 }, scanner.points)
      assert_in_delta 0.6, scanner.base_credit
    end
  end

  def test_feature_comments
    scan("verification_test.rb" => <<~RUBY) do |scanner, root|
      class FeaturesTest < Minitest::Test
        # @feature migrations
        # Timestamps must be real.
        test "timestamps" do
          allow_failure { assert true }
        end

        def test_archspec
          # @feature archspec
          assert true
        end

        test "ssrf to private networks" do # @feature ssrf
          assert true
        end

        # @feature ssrf
        def test_ssrf_to_own_host = assert(true)

        # @feature lost

        def test_unannotated = assert(true)
      end
    RUBY
      assert_equal(
        { "migrations" => %w[FeaturesTest#test_timestamps], "archspec" => %w[FeaturesTest#test_archspec],
          "ssrf" => %w[FeaturesTest#test_ssrf_to_private_networks FeaturesTest#test_ssrf_to_own_host] },
        scanner.features
      )
      assert_equal [ "#{root.join("verification_test.rb")}:20" ], scanner.stray_features
    end
  end
end
