# frozen_string_literal: true

require "test_helper"

class ConfigConversionTest < Minitest::Test
  include Lemans::Config::Conversion

  def test_integer
    assert_equal 100, integer!("100")
    assert_equal 5, integer!(5)

    error = assert_raises(Lemans::ConfigError) { integer!("many") }
    assert_equal 'cannot read "many" as an integer', error.message
  end

  def test_float
    assert_in_delta 5.0, float!("5.0")
    assert_in_delta 0.5, float!(0.5)

    error = assert_raises(Lemans::ConfigError) { float!(nil) }
    assert_equal "cannot read nil as a number", error.message
  end

  def test_seconds
    assert_equal 45, seconds!(45)
    assert_in_delta 0.5, seconds!("500ms")
    assert_equal 300.0, seconds!("300s")
    assert_equal 1800.0, seconds!("30m")
    assert_equal 3600.0, seconds!("1h")
    assert_equal 86_400.0, seconds!("1d")
    assert_equal 90.0, seconds!("90")

    error = assert_raises(Lemans::ConfigError) { seconds!("soon") }
    assert_includes error.message, "duration"
    assert_raises(Lemans::ConfigError) { seconds!(-1) }
  end
end
