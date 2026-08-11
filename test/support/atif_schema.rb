# frozen_string_literal: true

require "json"
require "json_skooma"

# ATIF conformance lives in the test suite: the emitter is deterministic, so
# proving its shape once in CI covers every trial. Schema generated from Harbor's pydantic models.
module ATIFSchema
  DIALECT = "2020-12"
  SCHEMA_PATH = Pathname(File.expand_path("atif-v1.7.json", __dir__))

  def self.schema
    @schema ||= begin
      JSONSkooma.create_registry(DIALECT)
      JSONSkooma::JSONSchema.new(JSON.parse(SCHEMA_PATH.read))
    end
  end

  # Skooma compares against the JSON document, so symbol keys and anything
  # else Ruby-shaped has to become JSON before it is judged.
  def self.errors(trajectory)
    result = schema.evaluate(JSON.parse(JSON.generate(trajectory)))
    return [] if result.valid?

    Array(result.output(:basic)["errors"]).map do |error|
      location = error["instanceLocation"].to_s
      "#{location.empty? ? "/" : location}: #{error["error"]}"
    end
  end

  def self.valid?(trajectory) = errors(trajectory).empty?
end
