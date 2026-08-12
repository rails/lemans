# frozen_string_literal: true

module Lemans
  module Results
    # Where a trial's dollar figure came from: a published $0.00 is only worth
    # reading if it can be told apart from "nobody could price this model".
    CostSource = Data.define(:name, :model, :priced_as, :registry) do
      def self.none = new(name: :none, model: nil, priced_as: nil, registry: nil)

      def to_h = { name: name, model: model, priced_as: priced_as, registry: registry }.compact
    end
  end
end
