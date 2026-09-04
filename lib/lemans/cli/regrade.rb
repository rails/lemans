# frozen_string_literal: true

require "json"
require "prism"

module Lemans
  class CLI < Thor
    # Re-grades stored results from the checks.json each trial left behind,
    # against a mapping: every check of the task as `fail` (required) or
    # `fail (allowed)` (extra), plus the grading section. Nothing runs.
    class Regrade
      ALLOWED = "fail (allowed)"
      CHECKS = "checks.json"

      Mapping = Struct.new(:checks, :base_credit, :points, keyword_init: true) do
        def self.from_json(data)
          checks = data["checks"] or raise ConfigError, "a mapping needs a `checks` section"
          grading = data["grading"] || {}
          declared = grading["points"] || {}
          allowed = checks.select { |_, status| status == ALLOWED }.keys
          new(checks:, base_credit: grading["base_credit"], points: allowed.to_h { [ it, declared.fetch(it, 1) ] })
        end

        def names = checks.keys.sort

        def allowed?(check) = points.key?(check)

        def grading = { base_credit:, points: }.compact
      end

      Change = Struct.new(:result, :reward, :credit, keyword_init: true)

      # Reads the grading schema off the test file without running it: every
      # `def test_*` and ActiveSupport `test "..."` is a check, an
      # `allow_failure` call inside makes it an extra worth its `points:`.
      class TestScanner < Prism::Visitor
        attr_reader :tests, :points, :base_credit

        def initialize
          super
          @scope = []
          @tests = []
          @points = {}
          @current = nil
        end

        def visit_module_node(node) = scoped(node) { super }

        def visit_class_node(node) = scoped(node) { super }

        def visit_def_node(node)
          return super unless node.name.start_with?("test_")

          within("#{@scope.join("::")}##{node.name}") { super }
        end

        def visit_call_node(node)
          case node.name
          when :test
            title = node.arguments&.arguments&.first
            if node.receiver.nil? && node.block && title.is_a?(Prism::StringNode)
              return within("#{@scope.join("::")}#test_#{title.unescaped.gsub(/\s+/, "_")}") { super }
            end
          when :allow_failure
            @points[@current] ||= points_of(node) if @current
          when :base_credit=
            @base_credit = node.arguments.arguments.first.value if node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :LemansReport
          end
          super
        end

        private

        def scoped(node)
          @scope.push(node.constant_path.full_name)
          yield
        ensure
          @scope.pop
        end

        def within(check)
          @tests << check
          @current = check
          yield
        ensure
          @current = nil
        end

        def points_of(node)
          keywords = node.arguments&.arguments&.grep(Prism::KeywordHashNode)&.first
          pair = keywords&.elements&.find { it.is_a?(Prism::AssocNode) && it.key.is_a?(Prism::SymbolNode) && it.key.unescaped == "points" }
          pair ? pair.value.value : 1
        end
      end

      class << self
        def mapping_from_file(path) = Mapping.from_json(JSON.parse(File.read(path)))

        def mapping_for(task)
          local, = task.test_files.find { |_, remote| remote == "verification_test.rb" }
          raise ConfigError, "#{task.name} has no verification_test.rb to read the grading from" unless local

          scanner = TestScanner.new
          Prism.parse_file(local.to_s).value.accept(scanner)
          checks = scanner.tests.to_h { [ it, scanner.points.key?(it) ? ALLOWED : "fail" ] }
          Mapping.new(checks:, base_credit: scanner.base_credit, points: scanner.points)
        end
      end

      attr_reader :store, :task, :mapping

      def initialize(store, task, mapping:)
        @store = store
        @task = task
        @mapping = mapping
      end

      def results
        @results ||= store.query(task:).select(&:scored?).sort_by { it.id.to_s }
      end

      # A statically read mapping is only trusted once a stored checks.json
      # names exactly its checks.
      def verify_mapping!
        stored = results.lazy.filter_map { checks_of(it) }.first
        return unless stored

        names = stored.fetch("checks", {}).keys.sort
        return if names == mapping.names

        raise ConfigError, "the checks read from verification_test.rb do not match the stored #{CHECKS} " \
                           "(missing: #{(names - mapping.names).inspect}, unexpected: #{(mapping.names - names).inspect}); " \
                           "pass --mapping with a #{CHECKS}-shaped file"
      end

      def execute!
        changes = []
        skipped = []
        results.each do |result|
          checks = checks_of(result)
          next skipped << [ result, "no #{CHECKS}" ] unless checks
          next skipped << [ result, "#{CHECKS} names other checks than the mapping" ] unless checks.fetch("checks", {}).keys.sort == mapping.names

          change = regrade!(result, checks)
          change ? changes << change : skipped << [ result, "unchanged" ]
        end
        [ changes, skipped ]
      end

      private

      def checks_of(result)
        raw = store.read_artifact(result, CHECKS)
        raw && JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      def regrade!(result, checks)
        statuses = checks["checks"].to_h { |check, status| [ check, status_of(check, status) ] }
        failures = statuses.reject { |_, status| status == "pass" || status == ALLOWED }.keys
        allowed = checks.fetch("allowed_failures", {}).slice(*statuses.select { |_, status| status == ALLOWED }.keys)
        updated = { checks: statuses, failures:, allowed_failures: allowed }
        updated[:grading] = mapping.grading unless mapping.grading.empty?
        reward = failures.empty? ? 1.0 : 0.0
        credit = credit_of(statuses, reward)
        return if reward == result.reward && credit == result.credit && JSON.parse(JSON.generate(updated)) == checks

        store.save_artifact(result, "#{JSON.pretty_generate(updated)}\n", path: CHECKS, force: true)
        change = Change.new(result:, reward: [ result.reward, reward ], credit: [ result.credit, credit ])
        store.save(result.graded!(reward, credit:))
        change
      end

      def status_of(check, status)
        return status unless status == "fail" || status == ALLOWED

        mapping.allowed?(check) ? ALLOWED : "fail"
      end

      def credit_of(statuses, reward)
        return reward if mapping.base_credit.nil?
        return 0.0 if reward.zero?

        total = mapping.points.values.sum
        return reward if total.zero?

        passed = mapping.points.sum { |check, value| statuses[check] == "pass" ? value : 0 }
        (mapping.base_credit + (1 - mapping.base_credit) * (passed.to_f / total)).round(2)
      end
    end
  end
end
