# frozen_string_literal: true

module Lemans
  # Store is responsible for storing trial results and
  # querying them later.
  class Store
    # Prepares the store
    def setup
      # no-op
    end

    # Returns all run records
    def fetch
      raise NotImplementedError
    end

    # Persist the result
    def save(result)
      raise NotImplementedError
    end

    # Persist the result's file artifact
    # (contents could be eiher IO (file) or text).
    def save_artifact(result, contents, path:)
      raise NotImplementedError
    end
  end
end
