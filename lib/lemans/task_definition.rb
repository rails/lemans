# frozen_string_literal: true

require "pathname"
require "yaml"

module Lemans
  # A single task definition
  class TaskDefinition
    INSTRUCTION = "instruction.md"
    FRONTMATTER = /\A---\n(.*?)\n---\n/m

    class << self
      def load_from_directory(config, dir)
        dir = Pathname(dir)
        data = frontmatter(dir)

        task = new(config, data["name"] || dir.basename.to_s, dir:)
        task.description = data["description"].to_s if data["description"]
        task.difficulty = data["difficulty"].to_sym if data["difficulty"]
        task.tags = Array(data["tags"]).map(&:to_s) if data["tags"]
        task.metadata = data["metadata"] if data["metadata"]

        task
      end

      private

      def frontmatter(dir)
        path = dir.join(INSTRUCTION)
        raise ConfigError, "#{dir}: #{INSTRUCTION} is required" unless path.file?

        contents = path.read
        match = contents.match(FRONTMATTER)

        unless match
          raise ConfigError, "#{path}: frontmatter opens with --- but never closes" if contents.start_with?("---")

          return {}
        end

        data = YAML.safe_load(match[1], aliases: true) || {}
        raise ConfigError, "#{path}: frontmatter must be a mapping" unless data.is_a?(Hash)

        data
      rescue Psych::Exception => e
        raise ConfigError, "#{path}: #{e.message}"
      end
    end

    attr_reader :config, :name, :dir

    attr_accessor :difficulty, :tags, :description, :metadata

    def initialize(config, name, dir: nil)
      @config = config
      @name = name
      @dir = dir || config.tasks_dir.join(name)
      @difficulty = :easy
      @tags = []
      @description = ""
      @metadata = {}
    end

    # The story alone: frontmatter is for the harness, never for the agent.
    def instruction
      @instruction ||= dir.join(INSTRUCTION).read.sub(FRONTMATTER, "")
    end

    def digest
      @digest ||= Config::TreeDigest.call(dir)[0, 16]
    end
  end
end
