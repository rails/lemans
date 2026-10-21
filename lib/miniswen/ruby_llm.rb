# frozen_string_literal: true

require "ruby_llm"

# Logging configuration
RubyLLM.configure do |config|
  config.log_level = ENV["RUBYLLM_LOG_LEVEL"].to_sym if ENV["RUBYLLM_LOG_LEVEL"]
  config.logger = Logger.new(IO::NULL) unless ENV["MINISWEN_DEBUG"] == "1" || ENV["RUBYLLM_DEBUG"] == "1"
end

# About ten minutes of retries (1, 2, 4, ... 256s plus jitter): provider
# outages and rate-limit windows outlast the minute this used to allow.
RubyLLM.configure do |config|
  config.max_retries = 9
  config.retry_interval = 1
  config.retry_max_interval = 256
end

# ruby_llm reads no API keys from ENV on its own; the conventional variable is the provider's
# config option upcased.
RubyLLM.configure do |config|
  RubyLLM::Provider.providers.each_value do |provider|
    provider.configuration_requirements.each do |option|
      value = ENV.fetch(option.to_s.upcase, nil)
      config.public_send(:"#{option}=", value) if value
    end
  end
end

module Miniswen
  # A 200 cut off mid-body is a dropped connection, but ruby_llm doesn't retry it.
  module RetryTransientFailures
    def retry_exceptions = super + [ Faraday::ParsingError ]
  end

  # ruby_llm parses tool-call arguments while it builds the message, so one
  # malformed call would raise and take the whole completion with it. The raw
  # string goes through instead and bounces as a format error.
  module LenientToolArguments
    def parse_tool_call_arguments(tool_call, **)
      super
    rescue RubyLLM::ToolCallParseError
      tool_call.dig("function", "arguments")
    end

    def parse_function_call_arguments(arguments, **)
      super
    rescue RubyLLM::ToolCallParseError
      arguments
    end

    def parse_arguments(arguments, *)
      super
    rescue RubyLLM::ToolCallParseError
      arguments
    end
  end
end

RubyLLM::Transport::Connection.singleton_class.prepend(Miniswen::RetryTransientFailures)
[ RubyLLM::Protocols::ChatCompletions::Tools, RubyLLM::Protocols::Responses::Chat, RubyLLM::Protocols::Cohere::Tools ].each do |parser|
  parser.prepend(Miniswen::LenientToolArguments)
  parser.singleton_class.prepend(Miniswen::LenientToolArguments)
end
