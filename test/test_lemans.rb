# frozen_string_literal: true

require "test_helper"

class TestLemans < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Lemans::VERSION
  end

  def test_the_loader_finds_every_seam
    assert Lemans::Environments::Base
    assert Lemans::Config::NetworkPolicy
    assert Lemans::TaskDefinition::ImageSpec
  end
end
