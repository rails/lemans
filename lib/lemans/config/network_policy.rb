# frozen_string_literal: true

module Lemans
  class Config
    class NetworkPolicy # :nodoc:
      class << self
        def from_config(data)
          new(data.fetch("mode", "public"), data["hosts"])
        end
      end

      attr_reader :mode, :hosts

      def initialize(mode = "public", hosts = nil)
        @mode = mode
        @hosts = hosts
      end
    end
  end
end
