# frozen_string_literal: true

require "pathname"
require "prism"

module Lemans
  class Trial
    class Verifier
      # Reads the grading schema off the test files without running them: every
      # `def test_*` and ActiveSupport `test "..."` is a check, an
      # `allow_failure` call inside makes it an extra worth its `points:`, and
      # a `# @feature <name>` comment right above a check or inside it tracks
      # the check as that feature. Files required from the test file's
      # directory are read too: suites often live apart.
      class TestScanner < Prism::Visitor
        ENTRY = "verification_test.rb"
        FEATURE = /\A#\s*@feature\s+(\S+)/

        Span = Data.define(:check, :file, :lines)

        attr_reader :tests, :points, :features, :base_credit, :stray_features

        # The task's verification_test.rb scanned, nil when it has none
        def self.for(task)
          local, = task.test_files.find { |_, remote| remote == ENTRY }
          return unless local

          new(Pathname(local).dirname).tap { it.scan(Pathname(local)) }
        end

        def initialize(root)
          super()
          @root = root
          @scope = []
          @tests = []
          @points = {}
          @features = {}
          @stray_features = []
          @spans = []
          @current = nil
          @scanned = []
        end

        def scan(path)
          return if @scanned.include?(path)

          @scanned << path
          file = @file
          begin
            @file = path
            parsed = Prism.parse_file(path.to_s)
            parsed.value.accept(self)
            attach_features(path, parsed.comments)
          ensure
            @file = file
          end
        end

        def visit_module_node(node) = scoped(node) { super }

        def visit_class_node(node) = scoped(node) { super }

        def visit_def_node(node)
          return super unless node.name.start_with?("test_") && node.parameters.nil?

          within("#{@scope.join("::")}##{node.name}", node) { super }
        end

        def visit_call_node(node)
          case node.name
          when :test
            title = node.arguments&.arguments&.first
            if node.receiver.nil? && node.block && title.is_a?(Prism::StringNode)
              return within("#{@scope.join("::")}#test_#{title.unescaped.gsub(/\s+/, "_")}", node) { super }
            end
          when :allow_failure
            @points[@current] ||= points_of(node) if @current
          when :require, :require_relative
            required = node.arguments&.arguments&.first
            scan_required(node.name, required.unescaped) if node.receiver.nil? && required.is_a?(Prism::StringNode)
            return
          when :base_credit=
            @base_credit = node.arguments.arguments.first.value if node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :LemansReport
          end
          super
        end

        private

        def scan_required(how, name)
          path = (how == :require_relative ? @file.dirname : @root).join("#{name.delete_suffix(".rb")}.rb")
          scan(path) if path.file?
        end

        def scoped(node)
          @scope.push(node.constant_path.full_name)
          yield
        ensure
          @scope.pop
        end

        def within(check, node)
          @tests << check
          @spans << Span.new(check:, file: @file, lines: node.location.start_line..node.location.end_line)
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

        # A comment belongs to the check it sits in, or to the one its
        # comment block opens onto.
        def attach_features(path, comments)
          own_line = path.readlines.each_with_index.filter_map { |text, index| index + 1 if text.lstrip.start_with?("#") }
          spans = @spans.select { it.file == path }

          comments.each do |comment|
            name = comment.slice[FEATURE, 1] or next
            line = comment.location.start_line
            span = spans.find { it.lines.cover?(line) } ||
                   spans.find { |s| s.lines.begin > line && (line...s.lines.begin).all? { own_line.include?(it) } }
            next @stray_features << "#{path}:#{line}" unless span

            (@features[name] ||= []) << span.check unless @features[name]&.include?(span.check)
          end
        end
      end
    end
  end
end
