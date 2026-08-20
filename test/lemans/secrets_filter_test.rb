# frozen_string_literal: true

require "test_helper"

class SecretsFilterTest < Minitest::Test
  def test_filter
    filter = Lemans::SecretsFilter.new([ "sk-or-v1-abcdef123456", "dtn_0123456789", nil, "", "short" ])

    assert_equal "key=<filtered> and <filtered>", filter.filter("key=sk-or-v1-abcdef123456 and dtn_0123456789")
    assert_equal "short is kept, nothing else here", filter.filter("short is kept, nothing else here")
    assert_equal "bin \xFF <filtered>".b, filter.filter("bin \xFF sk-or-v1-abcdef123456".b)
    assert_equal "as is", Lemans::SecretsFilter.new([]).filter("as is")
  end

  def test_default
    ENV["LEMANSTEST_API_KEY"] = "prov-key-0123456789"
    ENV["LEMANSTEST_TOKEN"] = "tok-0123456789"
    ENV["LEMANSTEST_MODEL"] = "not-secret-just-long"
    filter = Lemans::SecretsFilter.default

    assert_equal "<filtered> <filtered>", filter.filter("prov-key-0123456789 tok-0123456789")
    assert_equal "not-secret-just-long", filter.filter("not-secret-just-long")
  ensure
    ENV.delete("LEMANSTEST_API_KEY")
    ENV.delete("LEMANSTEST_TOKEN")
    ENV.delete("LEMANSTEST_MODEL")
  end
end
