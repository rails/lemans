# frozen_string_literal: true

require "test_helper"

class MiniswenSharedBackoffTest < Minitest::Test
  def setup = Miniswen::SharedBackoff.reset!

  def teardown = Miniswen::SharedBackoff.reset!

  def connection(responses)
    stubs = Faraday::Adapter::Test::Stubs.new
    responses.each { |status, headers| stubs.post("/v1/messages") { [ status, headers, "{}" ] } }
    Faraday.new("https://api.anthropic.com") do |faraday|
      faraday.use Miniswen::SharedBackoff
      faraday.adapter :test, stubs
    end
  end

  def test_backoff_from_rejections_and_exhausted_windows
    connection([ [ 429, { "retry-after" => "7" } ] ]).post("/v1/messages")
    after_retry = Miniswen::SharedBackoff.remaining("api.anthropic.com")
    Miniswen::SharedBackoff.reset!
    reset = (Time.now + 40).utc.iso8601
    connection([ [ 200, { "anthropic-ratelimit-input-tokens-remaining" => "0", "anthropic-ratelimit-input-tokens-reset" => reset,
                          "anthropic-ratelimit-requests-remaining" => "12", "anthropic-ratelimit-requests-reset" => reset } ] ])
      .post("/v1/messages")
    after_window = Miniswen::SharedBackoff.remaining("api.anthropic.com")
    Miniswen::SharedBackoff.reset!
    connection([ [ 500, { "retry-after" => "30" } ], [ 200, {} ] ]).post("/v1/messages")

    assert_in_delta 7, after_retry, 0.5
    assert_in_delta 40, after_window, 1.5
    assert_operator Miniswen::SharedBackoff.remaining("api.anthropic.com"), :<=, 0
    assert_operator Miniswen::SharedBackoff.remaining("api.openai.com"), :<=, 0
  end

  def test_concurrent_requests_wait_out_the_pause
    Miniswen::SharedBackoff.pause("api.anthropic.com", 0.3)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    threads = Array.new(2) { Thread.new { connection([ [ 200, {} ] ]).post("/v1/messages") } }
    threads.each(&:join)

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, 0.3
  end

  def test_pauses_are_capped_and_installed_on_every_connection
    connection([ [ 529, { "retry-after" => "100000" } ] ]).post("/v1/messages")
    handlers = RubyLLM::Transport::Connection.build(
      RubyLLM::Transport::Connection::Settings.new(api_base: "https://api.anthropic.com", adapter: :net_http, timeout: 1,
                                                    max_retries: 0, retry_interval: 1, retry_max_interval: 1,
                                                    retry_interval_randomness: 0, retry_backoff_factor: 2)
    ).builder.handlers.map(&:klass)

    assert_operator Miniswen::SharedBackoff.remaining("api.anthropic.com"), :<=, RubyLLM.config.retry_max_interval
    assert_equal Miniswen::SharedBackoff, handlers.last
  end
end
