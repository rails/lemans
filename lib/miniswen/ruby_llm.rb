# frozen_string_literal: true

require "ruby_llm"

# Logging configuration
RubyLLM.configure do |config|
  config.log_level = ENV.fetch("RUBYLLM_LOG_LEVEL", "info").to_sym
  config.logger = Logger.new(IO::NULL) unless ENV["MINISWEN_DEBUG"] == "1"
end

# About five minutes of retries (1, 2, 4, ... 128s plus jitter): provider
# outages and rate-limit windows outlast the minute this used to allow.
RubyLLM.configure do |config|
  config.max_retries = 8
  config.retry_interval = 1
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
  # OpenRouter requires reasoning_details replayed exactly as received; ruby_llm
  # rebuilds them from its collapsed text+signature pair, and providers that
  # sign each block separately reject that as a corrupted thought signature.
  module VerbatimReasoningDetails
    def format_thinking(msg)
      details = msg.thinking.respond_to?(:details) ? msg.thinking.details : nil
      details && !details.empty? ? { reasoning_details: details } : super
    end
  end

  # ruby_llm lists SSL errors as fatal, but a handshake reset never sent the
  # request; a 200 with a truncated JSON body is the same dropped connection
  # one step later.
  module RetryTransientFailures
    def retry_exceptions = super + [ Faraday::SSLError, Faraday::ParsingError ]
  end
end

RubyLLM::Providers::OpenRouter.prepend(Miniswen::VerbatimReasoningDetails)
RubyLLM::Connection.prepend(Miniswen::RetryTransientFailures)
