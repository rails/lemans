# frozen_string_literal: true

require "ruby_llm/test"

require "miniswen/agent"
require "miniswen/environment"

module Miniswen
  # Test support for callers driving Miniswen::Agent without a real provider:
  # a "test" model family resolving through ruby_llm's real path, an in-process
  # FakeEnv shell, and stub_llm/llm_answer helpers on top of RubyLLM::Test's
  # response queue. Include into a Minitest case; stubs reset before each test.
  module Testing
    # Registered under the :test slug; completions never reach it, RubyLLM::Test
    # intercepts them at resolve time.
    class Provider < RubyLLM::Provider
      def self.slug = "test"

      def api_base = "http://test.invalid"
    end

    # $20/M input (fresh and cached) and $400/M output price the default answer
    # (95 fresh + 5 cached input tokens, 20 output tokens) at exactly $0.01.
    PRICED_MODEL = RubyLLM::Model::Info.new(
      id: "test", name: "Test", provider: "test",
      capabilities: %w[function_calling],
      modalities: { input: %w[text], output: %w[text] },
      pricing: { text_tokens: { standard: {
        input_per_million: 20.0, cached_input_per_million: 20.0, output_per_million: 400.0
      } } }
    )

    UNPRICED_MODEL = RubyLLM::Model::Info.new(
      id: "test-unpriced", name: "Test unpriced", provider: "test",
      capabilities: %w[function_calling],
      modalities: { input: %w[text], output: %w[text] }
    )

    MODELS = { PRICED_MODEL.id => PRICED_MODEL, UNPRICED_MODEL.id => UNPRICED_MODEL }.freeze

    # Serves the test models from ruby_llm's registry lookups.
    module FindTestModels
      def find(model_id, provider = nil)
        MODELS[model_id] || super
      end
    end

    RawResponse = Data.define(:body)

    SUBMIT = { content: "Done.", cmd: "echo #{Agent::SUBMIT_MARKER}" }.freeze

    # A shell made of a Hash. `echo` behaves like echo, so the submit marker
    # works the way it does in a real sandbox; anything else is looked up.
    class FakeEnv
      attr_reader :commands

      def initialize(canned = {})
        @canned = canned
        @commands = []
      end

      def on(command, output, exit_code: 0)
        @canned[command] = [exit_code, output]
      end

      def exec(command, timeout: nil, env: nil) # rubocop:disable Lint/UnusedMethodArgument
        @commands << command
        return result(0, command.delete_prefix("echo ")) if command.start_with?("echo ")

        exit_code, output = @canned.fetch(command, [0, ""])
        result(exit_code, output)
      end

      private

      def result(exit_code, output)
        Environment::ExecResult.new(exit_code: exit_code, output: output)
      end
    end

    def before_setup
      super
      RubyLLM::Test.reset
    end

    # Each answer is a command string, or a hash with :cmd (one command or many)
    # and/or :content, plus optional overrides (:tool_calls, :finish_reason,
    # :thinking, token counts). Overrides given here apply to every answer.
    def stub_llm(*answers, **overrides)
      RubyLLM::Test.stub_responses(*answers.map { llm_answer(_1, **overrides) })
    end

    def llm_answer(answer, **overrides)
      answer = { cmd: answer } if answer.is_a?(String)
      answer = answer.merge(overrides)
      raise ArgumentError, "an answer needs :cmd or :content" unless answer[:cmd] || answer[:content]

      calls = tool_calls_for(answer)
      RubyLLM::Message.new(
        role: :assistant,
        content: answer.fetch(:content, "Let me try."),
        tool_calls: calls,
        thinking: answer[:thinking] && RubyLLM::Thinking.new(text: answer[:thinking]),
        input_tokens: answer.fetch(:input_tokens, 95),
        output_tokens: answer.fetch(:output_tokens, 20),
        cached_tokens: answer.fetch(:cached_tokens, 5),
        thinking_tokens: answer[:thinking] && 40,
        raw: RawResponse.new(body: {
                               "choices" => [{
                                 "finish_reason" => answer.fetch(:finish_reason) { calls.empty? ? "stop" : "tool_calls" }
                               }]
                             })
      )
    end

    private

    def tool_calls_for(answer)
      calls = answer[:tool_calls] || Array(answer[:cmd]).map { { name: "bash", arguments: { "command" => _1 } } }
      calls.to_h do |call|
        id = call[:id] || "call_#{@llm_answer_ids = @llm_answer_ids.to_i + 1}"
        [id, RubyLLM::ToolCall.new(id: id, name: call[:name], arguments: call[:arguments])]
      end
    end
  end
end

RubyLLM::Provider.register(:test, Miniswen::Testing::Provider)
RubyLLM::Models.prepend(Miniswen::Testing::FindTestModels)
RubyLLM::Models.singleton_class.prepend(RubyLLM::Test::ResolveWithTestProvider)
