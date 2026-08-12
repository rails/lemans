# frozen_string_literal: true

begin
  require "debug" unless ENV["CI"] == "true"
rescue LoadError # rubocop:disable Lint/SuppressedException
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lemans"

require "minitest/autorun"
require "minitest/mock"

require_relative "support/fake_environment"
require_relative "support/atif_schema"

module BenchFixture
  ROOT = Pathname(File.expand_path("fixtures/bench", __dir__))

  def load_bench = Lemans::Bench.load(BenchFixture::ROOT)

  def load_task(bench = load_bench) = bench.tasks.fetch(0)
end
