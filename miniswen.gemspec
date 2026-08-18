# frozen_string_literal: true

require_relative "lib/miniswen/version"

Gem::Specification.new do |spec|
  spec.name = "miniswen"
  spec.version = Miniswen::VERSION
  spec.authors = ["Svyatoslav Kryukov", "Artur Petrov", "Vladimir Dementyev"]
  spec.email = %w[me@skryukov.dev ardecvz@gmail.com dementiev.vm@gmail.com]

  spec.summary = "A Ruby port of mini-swe-agent"
  spec.description = "A Ruby port of mini-swe-agent."
  spec.homepage = "https://github.com/rails/lemans"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata = {
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}/blob/main/README.md",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/miniswen/**/*", "lib/miniswen.rb", "exe/miniswen", "LICENSE.txt", "README.md"]
  spec.require_paths = ["lib"]

  spec.bindir = "exe"
  spec.executables = ["miniswen"]

  spec.add_dependency "logger"
  spec.add_dependency "ruby_llm", "~> 1.16"
end
