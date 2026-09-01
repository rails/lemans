# frozen_string_literal: true

module Lemans
  module Ext
    module DeepMerge
      refine Hash do
        def deep_merge(other)
          merge(other) { |_, base, over| base.is_a?(Hash) && over.is_a?(Hash) ? base.deep_merge(over) : over }
        end
      end
    end
  end
end
