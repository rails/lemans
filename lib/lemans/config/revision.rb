# frozen_string_literal: true

require "open3"

module Lemans
  class Config
    # Which revision of a bench produced a score.
    # Obtain either from git or from ENV["COMMIT_SHA"] (lemans-remote convention)
    class Revision
      class << self
        def detect(dir)
          commit, dirty = ENV["COMMIT_SHA"]&.split("~")
          return new(commit, dirty == "!") if commit

          commit = git("rev-parse", "HEAD", dir:)
          return new if commit.nil?

          status = git("status", "--porcelain", dir:)
          new(commit, status.nil? ? nil : !status.empty?)
        end

        private

        def git(*, dir:)
          output, status = Open3.capture2e("git", "-C", dir.to_s, *)
          status.success? ? output.strip : nil
        rescue SystemCallError
          nil
        end
      end

      attr_reader :commit, :dirty

      def initialize(commit = nil, dirty = nil)
        @commit = commit
        @dirty = dirty
      end

      def as_json(**) = { commit:, dirty: }

      def to_env = commit && "#{commit}#{"~!" if dirty}"
    end
  end
end
