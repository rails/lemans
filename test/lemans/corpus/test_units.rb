# frozen_string_literal: true

require "test_helper"

class CorpusUnitsTest < Minitest::Test
  def test_durations_read_the_way_an_author_writes_them
    assert_equal 1800.0, Lemans::Corpus::Units.seconds("30m", field: "t")
    assert_equal 300.0, Lemans::Corpus::Units.seconds("300s", field: "t")
    assert_equal 3600.0, Lemans::Corpus::Units.seconds("1h", field: "t")
    assert_equal 86_400.0, Lemans::Corpus::Units.seconds("1d", field: "t")
    assert_in_delta 0.5, Lemans::Corpus::Units.seconds("500ms", field: "t")
    assert_equal 42.0, Lemans::Corpus::Units.seconds(42, field: "t")
    assert_nil Lemans::Corpus::Units.seconds(nil, field: "t")
  end

  def test_sizes_read_the_way_an_author_writes_them
    assert_equal 2048, Lemans::Corpus::Units.megabytes("2GB", field: "s")
    assert_equal 512, Lemans::Corpus::Units.megabytes("512MB", field: "s")
    assert_equal 512, Lemans::Corpus::Units.megabytes(512, field: "s")
    assert_nil Lemans::Corpus::Units.megabytes(nil, field: "s")
  end

  def test_gibberish_is_a_config_error_naming_the_field
    error = assert_raises(Lemans::ConfigError) { Lemans::Corpus::Units.seconds("soon", field: "agent.timeout") }
    assert_includes error.message, "agent.timeout"

    assert_raises(Lemans::ConfigError) { Lemans::Corpus::Units.megabytes("big", field: "s") }
  end
end
