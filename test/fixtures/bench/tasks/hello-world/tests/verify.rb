# frozen_string_literal: true

require "minitest/autorun"

class HelloWorldTest < Minitest::Test
  GREETING = "hello"

  def test_the_greeting_landed
    assert File.exist?("/app/hello.txt"), "expected /app/hello.txt to exist"
    assert_equal GREETING, File.read("/app/hello.txt").strip
  end
end
