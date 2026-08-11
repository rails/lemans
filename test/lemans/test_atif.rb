# frozen_string_literal: true

require "test_helper"

# These tests guard the schema file itself: a bad copy of the schema would
# otherwise make every conformance assertion in the suite pass vacuously.
class ATIFTest < Minitest::Test
  def minimal_trajectory
    {
      schema_version: "ATIF-v1.7",
      agent: { name: "miniswen", version: "0.1.0" },
      steps: [{ step_id: 1, source: "user", message: "do the thing" }]
    }
  end

  def test_a_minimal_trajectory_conforms
    assert ATIFSchema.valid?(minimal_trajectory), ATIFSchema.errors(minimal_trajectory).join("\n")
  end

  def test_a_step_from_nowhere_is_named_in_the_refusal
    broken = minimal_trajectory
    broken[:steps][0][:source] = "the void"

    assert(ATIFSchema.errors(broken).any? { _1.include?("/steps/0") })
  end

  def test_an_agent_without_a_version_is_refused
    broken = minimal_trajectory
    broken[:agent].delete(:version)

    refute_predicate ATIFSchema.errors(broken), :empty?
  end
end
