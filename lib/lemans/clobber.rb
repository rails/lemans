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

    def call
      matches.each { FileUtils.remove_entry(_1.to_s) }
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
