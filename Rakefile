# frozen_string_literal: true

require "bundler/gem_helper"

Bundler::GemHelper.install_tasks(name: "lemans")
namespace :miniswen do
  Bundler::GemHelper.install_tasks(name: "miniswen")
end
require "minitest/test_task"

Minitest::TestTask.create do |t|
  t.warning = false
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[test rubocop]
