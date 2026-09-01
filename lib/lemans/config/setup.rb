# frozen_string_literal: true

module Lemans
  class Config
    # One phase's preparation: the files uploaded into the sandbox and the
    # commands run against them. A bare list is shorthand for commands only.
    class Setup
      class << self
        def from_config(data, root:)
          return if data.nil?

          conf = new
          case data
          when Hash
            conf.commands = Array(data["commands"])
            conf.files = Array(data["files"]).map do |entry|
              local, remote = entry.is_a?(Array) ? entry : [ entry, entry ]
              [ root.join(local), remote ]
            end
          else
            conf.commands = Array(data)
          end

          conf
        end
      end

      # Files are [local absolute, remote relative] pairs; commands run in order.
      attr_accessor :files, :commands

      def initialize
        @files = []
        @commands = []
      end

      def merge(other)
        dup.tap do |merged|
          merged.files = files + other.files
          merged.commands = commands + other.commands
        end
      end

      def empty? = files.empty? && commands.empty?

      def to_h = { "commands" => commands, "files" => files.map { |local, remote| [ local.to_s, remote ] } }
    end
  end
end
