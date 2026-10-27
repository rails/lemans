# frozen_string_literal: true

require "test_helper"

class ConfigImageSpecTest < Minitest::Test
  def test_plain_dockerfile
    with_context("Dockerfile" => "FROM ruby:3.4-slim\nCOPY . /app\n") do |dir|
      spec = Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile"), slug: "shared")

      refute_predicate spec, :composed?
      assert_equal "FROM ruby:3.4-slim\nCOPY . /app\n", spec.dockerfile
      assert_equal Lemans::Config::TreeDigest.call(dir), spec.digest
      assert_equal [ dir.join("Dockerfile") ], spec.dockerfiles
    end
  end

  def test_sibling_dockerfiles_get_their_own_names
    with_context("Dockerfile" => "FROM ruby:3.4-slim\n", "Dockerfile.codegraph" => "FROM ruby:3.5-slim\n") do |dir|
      base = Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile"), slug: "shared")
      variant = Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile.codegraph"), slug: "shared.codegraph")

      refute_equal base.name, variant.name
      refute_predicate variant, :composed?
      assert_equal "FROM ruby:3.5-slim\n", variant.dockerfile
    end
  end

  def test_composition
    with_context(
      "Dockerfile" => "ARG RUBY=3.4\nFROM ruby:${RUBY}-slim AS gems\nRUN bundle install\nFROM ruby:${RUBY}-slim\nCOPY . /app",
      "Dockerfile.codegraph" => "ARG GRAPH=1\nFROM ./Dockerfile\nRUN gem install codegraph -v $GRAPH\n",
      "Dockerfile.deep" => "FROM --platform=linux/amd64 ./Dockerfile.codegraph AS graph\nFROM graph\nRUN codegraph index\n"
    ) do |dir|
      variant = Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile.codegraph"), slug: "shared.codegraph")
      deep = Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile.deep"), slug: "shared.deep")

      assert_predicate variant, :composed?
      assert_equal [ dir.join("Dockerfile"), dir.join("Dockerfile.codegraph") ], variant.dockerfiles
      assert_equal <<~DOCKERFILE, variant.dockerfile
        ARG GRAPH=1
        ARG RUBY=3.4
        FROM ruby:${RUBY}-slim AS gems
        RUN bundle install
        FROM ruby:${RUBY}-slim AS lemans-dockerfile
        COPY . /app
        FROM lemans-dockerfile
        RUN gem install codegraph -v $GRAPH
      DOCKERFILE

      assert_equal 3, deep.dockerfiles.size
      assert_equal "FROM --platform=linux/amd64 lemans-dockerfile.codegraph AS graph\n", deep.dockerfile.lines[-3]
      assert_includes deep.dockerfile, "FROM lemans-dockerfile AS lemans-dockerfile.codegraph\n"
    end
  end

  def test_composition_keeps_a_named_last_stage
    with_context("Dockerfile" => "FROM ruby:3.4-slim AS app\n", "Dockerfile.codegraph" => "FROM ./Dockerfile\nRUN true\n") do |dir|
      variant = Lemans::Config::ImageSpec.dockerfile(dir.join("Dockerfile.codegraph"), slug: "shared.codegraph")

      assert_equal "FROM ruby:3.4-slim AS app\nFROM app\nRUN true\n", variant.dockerfile
    end
  end

  def test_composition_errors
    with_context(
      "Dockerfile.loop" => "FROM ./Dockerfile.loop\n",
      "Dockerfile.away" => "FROM ./docker/Dockerfile\n",
      "Dockerfile.two" => "FROM ./Dockerfile.loop\nFROM ./Dockerfile.away\n",
      "Dockerfile.missing" => "FROM ./Dockerfile\n"
    ) do |dir|
      build = ->(name) { assert_raises(Lemans::ConfigError) { Lemans::Config::ImageSpec.dockerfile(dir.join(name), slug: name) }.message }

      assert_includes build.("Dockerfile.loop"), "builds on itself"
      assert_includes build.("Dockerfile.away"), "must name a Dockerfile in the same directory"
      assert_includes build.("Dockerfile.two"), "may build on one sibling only"
      assert_equal "no Dockerfile at #{dir.join("Dockerfile")}", build.("Dockerfile.missing")
    end
  end

  private

  def with_context(files)
    Dir.mktmpdir do |dir|
      dir = Pathname(dir)
      files.each { |path, content| dir.join(path).write(content) }
      yield dir
    end
  end
end
