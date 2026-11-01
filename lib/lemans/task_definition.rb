# frozen_string_literal: true

require "pathname"
require "yaml"

module Lemans
  # A single task definition: an instruction, an environment, tests, a solution —
  # plus the task's projection of the bench config (setup and verifier sections
  # with per-task overrides applied). Anything lemans does not understand
  # belongs under `metadata`, copied untouched.
  class TaskDefinition
    INSTRUCTION = "instruction.md"
    ENVIRONMENT_DIR = "environment"
    TESTS_DIR = "tests"
    SOLUTION_DIR = "solution"

    FLAT_TEST = "verification_test.rb"
    FLAT_SOLUTION = "solution.patch"
    FLAT_SEED = "environment.patch"

    FRONTMATTER = /\A---\n(.*?)\n---\n/m
    STEP_SEPARATOR = /^---[ \t]*\n/

    STEP_TESTS = { "tests.%d" => :dir, "verification_test.%d.rb" => FLAT_TEST, "verify.%d" => "verify" }.freeze
    # The same step files, kept inside the shared tests/ directory
    SHARED_STEP_TESTS = { "verification_test.%d.rb" => FLAT_TEST, "verify.%d" => "verify" }.freeze
    # What the final step alone runs (see Config::Verifier::DEFAULT_COMMAND): never shipped to an earlier step
    FINAL_STEP_TESTS = [ FLAT_TEST, "verify", "test.sh" ].freeze
    STEP_SOLUTIONS = { "solution.%d" => :dir, "solution.%d.patch" => FLAT_SOLUTION,
                       "solve.%d" => "solve", "solve.%d.sh" => "solve.sh" }.freeze

    STEP_FILE = /\A(?:tests\.(?<test>\d+)|verification_test\.(?<test>\d+)\.rb|verify\.(?<test>\d+)|
                     solution\.(?<solution>\d+)(?:\.patch)?|solve\.(?<solution>\d+)(?:\.sh)?)\z/x

    VARIANT = "[a-z][a-z0-9_-]*"
    VARIANT_RULE = "a variant name is lowercase letters, digits, - and _, starting with a letter"
    VARIANT_NAME = /\A#{VARIANT}\z/
    # A variant's <kind>.<variant>.patch replaces the task's <kind>.patch, its <kind>+<variant>.patch goes on top
    VARIANT_FILE = /\A(?:environment[.+](?<variant>#{VARIANT})\.patch|solution[.+](?<variant>#{VARIANT})(?:\.\d+)?\.patch|
                        instruction\+(?<variant>#{VARIANT})\.md)\z/x
    # solution.<variant>.N.patch replaces step N's solution, solution+<variant>.N.patch goes on top of it
    VARIANT_STEP_SOLUTION = /\Asolution(?<separator>[.+])(?<variant>#{VARIANT})\.(?<step>\d+)\.patch\z/
    VARIANT_DOCKERFILE = /\ADockerfile\.(?!dockerignore\z)(?<variant>#{VARIANT})\z/

    class << self
      def load_from_directory(config, dir)
        dir = Pathname(dir)
        data = frontmatter(dir)
        config = Config.load_file(dir, parent: config) if Config::FILENAMES.any? { dir.join(it).file? }

        task = new(config, data["name"] || dir.basename.to_s, dir:)
        task.description = data["description"].to_s if data["description"]
        task.difficulty = data["difficulty"].to_sym if data["difficulty"]
        task.tags = Array(data["tags"]).map(&:to_s) if data["tags"]
        task.metadata = data["metadata"] if data["metadata"]
        task.environment_profile = data["environment"] if data["environment"]
        task.multistep = data["multistep"] if data.key?("multistep")

        declared_setup = Config::Setup.from_config(data["setup"], root: dir)
        refuse_config_collisions!(task, declared_setup, config.setup)
        task.setup = declared_setup

        if (variants = data["setup"].is_a?(Hash) && data["setup"]["variants"])
          task.variant_setups = variants.to_h do |variant, section|
            raise ConfigError, "#{dir}: setup.variants.#{variant}: #{VARIANT_RULE}" unless VARIANT_NAME.match?(variant.to_s)

            declared = Config::Setup.from_config(section, root: dir) || Config::Setup.new
            refuse_config_collisions!(task, declared, config.setup)
            [ variant.to_s, declared ]
          end
        end

        task.verifier.restore_paths = Config::Verifier.restore_paths!(data["restore"]) if data.key?("restore")
        if (declared = Config::Setup.from_config(data.dig("verifier", "setup"), root: dir))
          refuse_config_collisions!(task, declared, config.verifier.setup)
          task.verifier.setup = config.verifier.setup.merge(declared)
        end

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

        if (extras = data["verifier"].is_a?(Hash) ? data["verifier"].keys - [ "setup" ] : nil) && extras.any?
          raise ConfigError, "#{task.dir}: a task may only override verifier.setup, not verifier.#{extras.first}"
        end

        if (profile = task.environment_profile)
          unless task.config.environment.profiles.key?(profile)
            declared = task.config.environment.profiles.keys
            listing = declared.any? ? "declares #{declared.join(", ")}" : "declares none"
            raise ConfigError, "#{task.dir}: unknown environment #{profile} — bench.yml #{listing}"
          end

          raise ConfigError, "#{task.dir}: environment #{profile} and a local #{ENVIRONMENT_DIR}/Dockerfile are mutually exclusive" if
            task.environment_dockerfile.file?
        end

        raise ConfigError, "#{task.dir}: #{ENVIRONMENT_DIR}/Dockerfile is required when the bench declares no shared image or dockerfile and the task names no environment" unless
          task.environment_profile || task.config.environment.image || task.config.environment.dockerfile || task.environment_dockerfile.file?

        validate_steps!(task)
        validate_variants!(task)

        return unless task.test_files.empty?

        raise ConfigError, "#{task.dir}: #{TESTS_DIR}/ or a flat #{FLAT_TEST} is required — " \
                           "the verifier uploads it at verification time"
      end

      def validate_steps!(task)
        if task.multistep? && task.steps < 2
          raise ConfigError, "#{task.dir}: multistep: true but #{INSTRUCTION} holds a single section — " \
                             "separate step instructions with --- (the first section is the shared preamble)"
        end

        indexed_solutions = false
        entries = task.dir.children
        # Only step tests may carry an index inside tests/; a solution there is just a file.
        entries += task.tests_dir.children.select { |entry| entry.file? && STEP_FILE.match(entry.basename.to_s)&.[](:test) } if task.tests_dir.directory?
        entries.each do |entry|
          match = STEP_FILE.match(entry.basename.to_s) or next
          name = entry.relative_path_from(task.dir)

          raise ConfigError, "#{task.dir}: #{name} is an indexed step file, but the task is not multistep: true" unless
            task.multistep?

          step = (match[:test] || match[:solution]).to_i
          raise ConfigError, "#{task.dir}: #{name} names step #{step}, but the task has #{task.steps} steps" unless
            step.between?(1, task.steps)

          if match[:solution]
            indexed_solutions = true
          elsif step == task.steps
            raise ConfigError, "#{task.dir}: #{name} indexes the final step — the final verification keeps " \
                               "the unindexed name"
          end
        end

        return unless indexed_solutions && task.solution_files.any?

        raise ConfigError, "#{task.dir}: #{FLAT_SOLUTION} is the whole task's solution while indexed step solutions " \
                           "chain step by step — ship one or the other, not both"
      end

      def validate_variants!(task)
        names = task.dir.children.map { it.basename.to_s }
        if (stray = names.find { it.match?(/\Ainstruction\.[^.]+\.md\z/) })
          raise ConfigError, "#{task.dir}: #{stray} — a variant can only extend the instruction: " \
                             "name it #{stray.sub("instruction.", "instruction+")}"
        end

        task.variants.product(%w[environment solution]).each do |variant, kind|
          next unless names.include?("#{kind}.#{variant}.patch") && names.include?("#{kind}+#{variant}.patch")

          raise ConfigError, "#{task.dir}: #{kind}.#{variant}.patch replaces #{kind}.patch while " \
                             "#{kind}+#{variant}.patch extends it — ship one or the other"
        end

        validate_variant_step_solutions!(task, names)
      end

      def validate_variant_step_solutions!(task, names)
        indexed = names.filter_map { VARIANT_STEP_SOLUTION.match(it) }
        indexed.each do |match|
          name = match.to_s
          raise ConfigError, "#{task.dir}: #{name} is an indexed step file, but the task is not multistep: true" unless task.multistep?

          step = match[:step].to_i
          raise ConfigError, "#{task.dir}: #{name} names step #{step}, but the task has #{task.steps} steps" unless
            step.between?(1, task.steps)

          whole = "solution#{match[:separator]}#{match[:variant]}.patch"
          raise ConfigError, "#{task.dir}: #{whole} is the variant's whole-task patch while #{name} is a step's — " \
                             "ship one or the other" if names.include?(whole)

          if match[:separator] == "+" && names.include?(replacing = "solution.#{match[:variant]}.patch")
            raise ConfigError, "#{task.dir}: #{replacing} replaces the whole solution while #{name} extends it — " \
                               "ship one or the other"
          end

          next unless match[:separator] == "." && names.include?(extending = "solution+#{match[:variant]}.#{step}.patch")

          raise ConfigError, "#{task.dir}: #{name} replaces step #{step}'s solution while #{extending} extends it — " \
                             "ship one or the other"
        end
      end

      # Collisions would be resolved by upload order, so a task never gets to
      # shadow the bench-wide copy.
      def refuse_config_collisions!(task, declared, base)
        return unless declared

        shadowed = declared.files.map(&:last) & base.files.map(&:last)
        return if shadowed.empty?

        raise ConfigError, "#{task.dir}: setup.files names #{shadowed.first}, which the bench " \
                           "already ships to every task"
      end
    end

    attr_reader :config, :dir, :name, :variant

    attr_accessor :difficulty, :tags, :description, :metadata, :environment_profile, :multistep, :variant_setups

    alias multistep? multistep

    def initialize(config, name, dir: nil)
      @config = config
      @name = name

      @difficulty = :easy
      @tags = []
      @description = ""
      @metadata = {}
      @environment_profile = nil
      @multistep = false
      @variant_setups = {}

      @step = nil
      @variant = nil
      @dir = dir || config.tasks_dir.join(name)
    end

    # A copy of the task definition for a particular step
    # (so we can generated correct paths and instructions)
    def for_step(index) = dup.tap { it.step = index }

    # A copy of the task definition extended by a variant's files, setup and
    # instruction; grading stays the task's own
    def for_variant(variant)
      unless variants.include?(variant)
        listing = variants.any? ? "declares #{variants.join(", ")}" : "declares none"
        raise ConfigError, "#{dir}: unknown variant #{variant} — the task #{listing}"
      end

      dup.tap { it.variant = variant }
    end

    def variants
      files = dir.children.filter_map { VARIANT_FILE.match(it.basename.to_s)&.[](:variant) }
      dockerfiles = variant_dockerfile_dirs.flat_map { it.glob("Dockerfile.*") }
                                           .filter_map { VARIANT_DOCKERFILE.match(it.basename.to_s)&.[](:variant) }
      (variant_setups.keys + files + dockerfiles).uniq.sort
    end

    def final_step? = !multistep? || step == steps

    def steps = multistep? ? sections.size - 1 : 1

    # A variant's instruction extends the task's one
    def instruction
      if multistep?
        raise ArgumentError, "#{name} is multistep — only a step projection (for_step) has an instruction" unless step

        parts = [ sections[0], variant_instruction, sections.fetch(step) ]
      else
        return body unless variant_instruction

        parts = [ body, variant_instruction ]
      end

      "#{parts.compact.map(&:strip).join("\n\n")}\n"
    end

    def digest
      @digest ||= Config::TreeDigest.call(dir)[0, 16]
    end

    # The task's projection of the config sections: bench-wide values with the
    # task's own overrides applied. Phase machinery reads these, never the
    # global config.
    def setup
      @setup ||= begin
        declared = [ @declared_setup, variant_setups[variant] ].compact.reduce(Config::Setup.new, :merge)
        undeclared_seeds = seed_files.reject { |_, remote| declared.files.any? { it.last == remote } }
        config.setup.merge(declared).merge(Config::Setup.new.tap { it.files = undeclared_seeds })
      end
    end

    def setup=(declared)
      @declared_setup = declared
    end

    def verifier
      @verifier ||= config.verifier.dup
    end

    def environment = config.environment

    def seed? = dir.join(FLAT_SEED).file?

    # Remote names of the environment patches, in the order they apply
    def seeds = seed_files.map(&:last)

    # [absolute, remote-relative] pairs. Tests stay on the harness side while
    # the agent works; uploaded into the sandbox only at verification.
    #
    # A multistep task keeps one tests/ directory: whatever in it carries no
    # step index (helpers, fixtures) ships with every verified step, the
    # step's own verification_test.N.rb ships as verification_test.rb, and
    # the unindexed verification_test.rb stays with the final step.
    def test_files
      return final_test_files unless step && !final_step?

      indexed = step_files(STEP_TESTS) + step_files(SHARED_STEP_TESTS, root: tests_dir)
      return [] if indexed.empty?

      shared_test_files.reject { |_, remote| FINAL_STEP_TESTS.include?(remote) } + indexed
    end

    def verifiable? = test_files.any?

    # A lone whole-task solution is applied before the first step: intermediate
    # gates must see it, and later steps have nothing left to add. A variant's
    # replacing patch is such a lone solution; its extending patch ships with
    # the step that completes the task's own solution.
    #
    # Per step, solution.<variant>.N.patch replaces step N's solution (the
    # rest keep the task's own, a lone one dropped) and
    # solution+<variant>.N.patch goes on top of it.
    def solution_files
      if (replacing = variant_path("solution.%s.patch"))&.file?
        return step && step > 1 ? [] : [ [ replacing, FLAT_SOLUTION ] ]
      end

      files =
        if (replacing = step && variant_path("solution.%s.#{step}.patch"))&.file?
          [ [ replacing, FLAT_SOLUTION ] ]
        elsif variant_step_solutions?(".") && !indexed_solutions?
          []
        else
          own_solution_files
        end

      whole = variant_path("solution+%s.patch")
      extending =
        if whole&.file?
          whole if step.nil? || step == (stepwise_solutions? ? steps : 1)
        elsif step
          variant_path("solution+%s.#{step}.patch")
        end
      return files unless extending&.file?

      files + [ [ extending, extending.basename.to_s ] ]
    end

    # True for the later steps of a multistep task whose lone solution already
    # shipped with step 1
    def solution_applied_earlier?
      return false unless step && step > 1
      return true if variant_path("solution.%s.patch")&.file?

      !stepwise_solutions? &&
        (solution_dir.directory? || dir.join(FLAT_SOLUTION).file? || !!variant_path("solution+%s.patch")&.file?)
    end

    def solution? = solution_files.any?

    def tests_dir = dir.join(TESTS_DIR)

    def solution_dir = dir.join(SOLUTION_DIR)

    def environment_dockerfile = dir.join(ENVIRONMENT_DIR, "Dockerfile")

    # A variant's Dockerfile.<variant> — the task's own, or a sibling of the
    # Dockerfile the task builds from — replaces the image it would get
    def environment_image
      dockerfile, slug = base_dockerfile
      if (variant_file = variant_dockerfile)
        own = variant_file.dirname == environment_dockerfile.dirname
        Config::ImageSpec.dockerfile(variant_file, slug: own ? name : "#{slug}##{variant}")
      elsif dockerfile
        Config::ImageSpec.dockerfile(dockerfile, slug:)
      else
        Config::ImageSpec.registry(environment.profiles[environment_profile]&.image || environment.image)
      end
    end

    protected attr_writer :step

    protected def variant=(name)
      @variant = name
      @name = "#{@name}##{variant}"
      @setup = nil
    end

    private

    attr_reader :step

    def body
      @body ||= dir.join(INSTRUCTION).read.sub(FRONTMATTER, "")
    end

    def sections
      @sections ||= body.split(STEP_SEPARATOR)
    end

    def indexed_solutions? = (1..steps).any? { step_files(STEP_SOLUTIONS, it).any? }

    def stepwise_solutions? = indexed_solutions? || variant_step_solutions?(".")

    def variant_step_solutions?(separator)
      variant && (1..steps).any? { dir.join("solution#{separator}#{variant}.#{it}.patch").file? }
    end

    # A task may keep its final test flat at the root and use tests/ for shared files
    def final_test_files
      return flat(FLAT_TEST) unless tests_dir.directory?

      shared_test_files + flat(FLAT_TEST)
    end

    # Everything under tests/ that no step claims for itself
    def shared_test_files
      return [] unless tests_dir.directory?

      expand(tests_dir).reject { |_, remote| STEP_FILE.match?(remote) }
    end

    def step_files(patterns, index = step, root: dir)
      patterns.flat_map do |pattern, remote|
        path = root.join(format(pattern, index))
        if remote == :dir
          path.directory? ? expand(path) : []
        else
          path.file? ? [ [ path, remote ] ] : []
        end
      end
    end

    def own_solution_files
      if step
        return step_files(STEP_SOLUTIONS) if indexed_solutions?
        return [] if multistep? && step > 1
      end

      solution_dir.directory? ? expand(solution_dir) : flat(FLAT_SOLUTION)
    end

    def seed_files
      replacing = variant_path("environment.%s.patch")
      return flat(replacing.basename.to_s) if replacing&.file?

      extending = variant_path("environment+%s.patch")
      flat(FLAT_SEED) + (extending&.file? ? flat(extending.basename.to_s) : [])
    end

    def variant_path(pattern) = variant && dir.join(format(pattern, variant))

    def base_dockerfile
      if (profile = environment.profiles[environment_profile])
        [ profile.dockerfile, environment_profile ] if profile.dockerfile
      elsif environment_dockerfile.file?
        [ environment_dockerfile, name ]
      elsif environment.dockerfile
        [ environment.dockerfile, "shared" ]
      end
    end

    def variant_dockerfile_dirs = [ environment_dockerfile.dirname, base_dockerfile&.first&.dirname ].compact.uniq

    def variant_dockerfile
      return unless variant

      variant_dockerfile_dirs.map { it.join("Dockerfile.#{variant}") }.find(&:file?)
    end

    def variant_instruction
      path = variant_path("instruction+%s.md")
      path.read if path&.file?
    end

    # Dotfiles included, matching TreeDigest: the files a digest records are
    # exactly the files that ship.
    def expand(root)
      root.glob("**/*", File::FNM_DOTMATCH).select(&:file?).map { [ it, it.relative_path_from(root).to_s ] }
    end

    def flat(filename)
      path = dir.join(filename)
      path.file? ? [ [ path, filename ] ] : []
    end
  end
end
