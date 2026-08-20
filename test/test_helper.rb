# frozen_string_literal: true

begin
  require "debug" unless ENV["CI"] == "true"
rescue LoadError # rubocop:disable Lint/SuppressedException
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "lemans"

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"

require_relative "support/fake_environment"
require_relative "support/atif_schema"

module BenchFixture
  ROOT = Pathname(File.expand_path("fixtures/bench", __dir__))

  def load_config = Lemans::Config.load_file(BenchFixture::ROOT.to_s)

  def load_task(config = load_config) = config.tasks.fetch(0)

  def with_task_dir(name)
    Dir.mktmpdir do |dir|
      task_dir = Pathname(dir).join(name)
      task_dir.join("tests").mkpath
      task_dir.join("tests/test.sh").write("exit 0\n")
      task_dir.join("environment").mkpath
      task_dir.join("environment/Dockerfile").write("FROM scratch\n")
      task_dir.join("instruction.md").write("---\ndescription: #{name}\n---\nFix it.\n")
      yield task_dir
    end
  end
end
