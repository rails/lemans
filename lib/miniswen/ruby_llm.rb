# frozen_string_literal: true

require "ruby_llm"

# Logging configuration
RubyLLM.configure do |config|
  config.log_level = ENV.fetch("RUBYLLM_LOG_LEVEL", "info").to_sym
  config.logger = Logger.new(IO::NULL) unless ENV["MINISWEN_DEBUG"] == "1"
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
