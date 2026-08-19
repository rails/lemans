# frozen_string_literal: true

require "test_helper"

class RunnerExecutorTest < Minitest::Test
  FakeTask = Struct.new(:value) do
    def run = value
  end

  BrokenTask = Class.new do
    def run = raise "boom"
  end

  def build_executor(concurrency = 4) = Lemans::Runner::Executor.new(concurrency)

  def test_collects_results_from_all_tasks
    executor = build_executor
    results = executor.start
    10.times { executor << FakeTask.new(it) }
    executor.shutdown

    assert_equal (0..9).to_a, results.results.sort
  end

  def test_error_poisons_the_run
    executor = build_executor(2)
    executor.start
    executor << FakeTask.new(1)
    executor << BrokenTask.new

    error = assert_raises(RuntimeError) { executor.shutdown }

    assert_equal "boom", error.message
  end

  def test_terminate_abandons_in_flight_tasks
    started = Queue.new
    blocker = Queue.new
    task = FakeTask.new(nil)
    task.define_singleton_method(:run) do
      started << :here
      blocker.pop
      :done
    end

    executor = build_executor(1)
    results = executor.start
    executor << task
    executor << FakeTask.new(:queued)
    started.pop
    executor.terminate

    assert_empty results.results
  end
end
