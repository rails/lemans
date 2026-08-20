# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in lemans.gemspec
gemspec name: "miniswen"
gemspec name: "lemans"

gem "debug", platform: :mri unless ENV["CI"] == "true"
gem "ruby-lsp", require: false unless ENV["CI"] == "true"

gem "irb"
# For lemans-remote to work
gem "openssl", ">= 3.3"
gem "rake", "~> 13.0"

gem "json_skooma", "~> 0.2"
gem "minitest", "~> 6.0"
gem "minitest-mock", "~> 5.27"
gem "rubocop", "~> 1.89"

gem "ruby_llm-test", "~> 0.2.0"
