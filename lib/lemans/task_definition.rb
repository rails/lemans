# frozen_string_literal: true

require "digest"
require "pathname"
require "yaml"

module Lemans
  # A single task definition: an instruction, an environment, tests, a solution.
  # Anything lemans does not understand belongs under `metadata`, copied untouched.
  class TaskDefinition
    INSTRUCTION = "instruction.md"
    ENVIRONMENT_DIR = "environment"
    TESTS_DIR = "tests"
    SOLUTION_DIR = "solution"

    FLAT_TEST = "verification_test.rb"
    FLAT_SOLUTION = "solution.patch"
    FLAT_SEED = "environment.patch"

    FRONTMATTER = /\A---\n(.*?)\n---\n/m

    # An image, either already published or built from a task's Dockerfile.
    # Built images are named by content digest, so reuse is only ever of the identical thing.
    class ImageSpec
      attr_reader :reference, :dockerfile_path, :slug, :digest

      def self.registry(reference) = new(reference:)

      def self.dockerfile(path, slug:)
        path = Pathname(path)
        raise ConfigError, "no Dockerfile at #{path}" unless path.file?

        new(dockerfile_path: path, slug:)
      end

      def initialize(reference: nil, dockerfile_path: nil, slug: nil)
        @reference = reference
        @dockerfile_path = dockerfile_path
        @slug = slug
        # Hashing the reference gives backends one answer to "is this the same image" either way.
        @digest = built? ? Config::TreeDigest.call(context_dir) : Digest::SHA256.hexdigest(reference.to_s)
      end

      def built? = !dockerfile_path.nil?

      def context_dir = dockerfile_path&.dirname

      def name
        built? ? "lemans-#{digest[0, 32]}" : reference
      end

      def to_s = name
    end

    class << self
      include Config::Conversion

      def load_from_directory(config, dir)
        dir = Pathname(dir)
        data = frontmatter(dir)

        task = new(config, data["name"] || dir.basename.to_s, dir:)
        task.description = data["description"].to_s if data["description"]
        task.difficulty = data["difficulty"].to_sym if data["difficulty"]
        task.tags = Array(data["tags"]).map(&:to_s) if data["tags"]
        task.metadata = data["metadata"] if data["metadata"]
        task.files = setup_files!(data["files"], root: dir) if data["files"]
        task.restore = Array(data["restore"]).map { restore_path!(it) } if data.key?("restore")

        validate!(task, data)
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

      def validate!(task, data)
        if data.key?("overrides")
          named = data["overrides"].is_a?(Hash) && data["overrides"].any? ? " (#{data["overrides"].keys.join(", ")})" : ""
          raise ConfigError, "#{task.dir}: a task cannot override the frozen profile#{named} — " \
                             "what has to vary belongs in bench.yml, where it varies for every trial"
        end

        raise ConfigError, "#{task.dir}: #{ENVIRONMENT_DIR}/Dockerfile is required when bench.yml names no shared image" unless
          task.config.environment.image || task.environment_dockerfile.file?

        if task.test_files.empty?
          raise ConfigError, "#{task.dir}: #{TESTS_DIR}/ or a flat #{FLAT_TEST} is required — " \
                             "the verifier uploads it at verification time"
        end

        refuse_config_collisions!(task)
      end

      # Collisions would be resolved by upload order, so a task never gets to
      # shadow the bench-wide copy.
      def refuse_config_collisions!(task)
        SETUP_PHASES.each do |phase|
          shadowed = task.setup_files(phase) & task.config.setup_files(phase)
          next if shadowed.empty?

          raise ConfigError, "#{task.dir}: files.#{phase} names #{shadowed.first}, which the bench " \
                             "already ships to every task"
        end
      end
    end

    attr_reader :config, :name, :dir

    attr_accessor :difficulty, :tags, :description, :metadata, :files, :restore

    def initialize(config, name, dir: nil)
      @config = config
      @name = name
      @dir = dir || config.tasks_dir.join(name)
      @difficulty = :easy
      @tags = []
      @description = ""
      @metadata = {}
      @files = { environment: [], verifier: [] }
      @restore = nil
    end

    # The story alone: frontmatter is for the harness, never for the agent.
    def instruction
      @instruction ||= dir.join(INSTRUCTION).read.sub(FRONTMATTER, "")
    end

    def digest
      @digest ||= Config::TreeDigest.call(dir)[0, 16]
    end

    def setup_files(phase)
      declared = files.fetch(phase.to_sym, [])
      seed = Pathname(FLAT_SEED)
      return declared unless phase.to_sym == :environment && dir.join(seed).file? && !declared.include?(seed)

      declared + [seed]
    end

    def restore_paths = restore || config.verifier.restore_paths

    # [absolute, remote-relative] pairs. Tests stay on the harness side while
    # the agent works; uploaded into the sandbox only at verification.
    def test_files
      tests_dir.directory? ? expand(tests_dir) : flat(FLAT_TEST)
    end

    def solution_files
      solution_dir.directory? ? expand(solution_dir) : flat(FLAT_SOLUTION)
    end

    def solution? = solution_files.any?

    def tests_dir = dir.join(TESTS_DIR)

    def solution_dir = dir.join(SOLUTION_DIR)

    def environment_dockerfile = dir.join(ENVIRONMENT_DIR, "Dockerfile")

    def environment_image
      if config.environment.image
        ImageSpec.registry(config.environment.image)
      else
        ImageSpec.dockerfile(environment_dockerfile, slug: name)
      end
    end

    private

    # Dotfiles included, matching TreeDigest: the files a digest records are
    # exactly the files that ship.
    def expand(root)
      root.glob("**/*", File::FNM_DOTMATCH).select(&:file?).map { [it, it.relative_path_from(root).to_s] }
    end

    def flat(filename)
      path = dir.join(filename)
      path.file? ? [[path, filename]] : []
    end
  end
end
