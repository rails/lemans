# frozen_string_literal: true

require "test_helper"

class OutcomeTest < Minitest::Test
  def test_a_budget_failure_is_scored_and_an_infrastructure_failure_is_not
    assert_predicate Lemans::Results::Outcome.new(:cost_ceiling_reached), :scored?
    assert_predicate Lemans::Results::Outcome.new(:agent_timeout), :scored?
    refute_predicate Lemans::Results::Outcome.new(:environment_error), :scored?
    refute_predicate Lemans::Results::Outcome.new(:verifier_error), :scored?
  end

  def test_an_outcome_nobody_defined_is_refused
    assert_raises(ArgumentError) { Lemans::Results::Outcome.new(:vibes) }
  end

  def test_it_serializes_with_its_detail
    outcome = Lemans::Results::Outcome.new(:verifier_error, detail: "wrote no reward")

    assert_equal({ name: :verifier_error, scored: false, detail: "wrote no reward" }, outcome.to_h)
  end
end
