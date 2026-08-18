# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"

module Lemans
  # Deletes run directories based on the provided filters.
  class Clobber
    TRIAL_DIR = /\A(?<task>.+)__[A-Za-z0-9]{7}\z/

    def initialize(runs_dir:, tasks: [], ttl_sec: nil, invalid: false)
      @runs_dir = Pathname(runs_dir)
      @tasks = Array(tasks)
      @ttl_sec = ttl_sec
      @invalid = invalid
    end

    def matches
      @matches ||= select_matches
    end

    # Deletes everything it can, says what it could not, and returns what it
    # actually removed — the caller's "deleted N" must not count survivors.
    def call
      matches.select do |entry|
        FileUtils.remove_entry(entry.to_s)
        true
      rescue SystemCallError => e
        warn "lemans: could not delete #{entry.basename}: #{e.message}"
        false
      end
    end

    private

    attr_reader :runs_dir, :tasks, :ttl_sec

    def select_matches
      return [] unless runs_dir.directory?

      runs_dir.children.sort.select do |entry|
        next false unless entry.directory?

        task = task_name(entry)
        next false if task.nil?

        (tasks.empty? || tasks.include?(task)) &&
          (ttl_sec.nil? || age_sec(entry) > ttl_sec) &&
          (!@invalid || invalid?(entry))
      end
    end

    def task_name(entry) = TRIAL_DIR.match(entry.basename.to_s)&.[](:task)

    def age_sec(entry) = Time.now - entry.mtime

    # A trial that measured nothing; an unreadable result counts — it will
    # never be read as anything else.
    def invalid?(entry)
      JSON.parse(entry.join("result.json").read).dig("outcome", "scored") != true
    rescue JSON::ParserError, SystemCallError, IOError
      true
    end
  end
end
