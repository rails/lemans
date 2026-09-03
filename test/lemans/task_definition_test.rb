# frozen_string_literal: true

require "test_helper"

class TaskDefinitionTest < Minitest::Test
  include BenchFixture

  def load_task(dir) = Lemans::TaskDefinition.load_from_directory(Lemans::Config.new, dir)

  def with_multistep_dir
    with_task_dir("multi") do |dir|
      dir.join("instruction.md").write(<<~MD)
        ---
        multistep: true
        ---
        Shared preamble.

        ---

        Do step one.

        ---

        Do step two.
      MD
      yield dir
    end
  end

  def test_load
    task = Lemans::TaskDefinition.load_from_directory(load_config, BenchFixture::ROOT.join("tasks/hello-world"))

    assert_equal "hello-world", task.name
    assert_equal "Prove the harness end to end", task.description
    assert_equal :easy, task.difficulty
    assert_equal [ "infrastructure" ], task.tags
    assert_equal "infrastructure", task.metadata["category"]
    assert_match(/\A[0-9a-f]{16}\z/, task.digest)
    assert_includes task.instruction, "hello.txt"
    refute_includes task.instruction, "---"
  end

  def test_frontmatter_defaults
    with_task_dir("minimal") do |dir|
      dir.join("instruction.md").write("Fix it.\n")
      task = load_task(dir)

      assert_equal "minimal", task.name
      assert_equal :easy, task.difficulty
      assert_empty task.tags
      assert_empty task.metadata
      assert_nil task.base_reward
    end
  end

  def test_base_reward
    with_task_dir("weighted") do |dir|
      dir.join("instruction.md").write("---\nbase_reward: 25\n---\nFix it.\n")
      task = load_task(dir)

      assert_in_delta 25.0, task.base_reward

      [ 0, -1, ".nan", "many" ].each do |value|
        dir.join("instruction.md").write("---\nbase_reward: #{value}\n---\nFix it.\n")

        error = assert_raises(Lemans::ConfigError) { load_task(dir) }

        assert_includes error.message, "base_reward must be finite and greater than zero"
      end
    end
  end

  def test_setup_projection_appends_the_seed
    with_task_dir("seeded") do |dir|
      dir.join("environment.patch").write("diff --git a/x b/x\n")
      task = load_task(dir)

      assert_predicate task, :seed?
      assert_equal [ "environment.patch" ], task.setup.files.map(&:last)
    end
  end

  def test_task_sections_extend_the_bench_ones_without_touching_them
    with_task_dir("custom") do |dir|
      dir.join("instruction.md").write(<<~MD)
        ---
        setup:
          commands: [make prep]
          files: [tests/test.sh]
        restore: [tests]
        verifier:
          setup: [make verify-prep]
        ---
        Go.
      MD
      task = load_task(dir)

      assert_includes task.setup.commands, "make prep"
      assert_includes task.setup.files.map(&:last), "tests/test.sh"
      assert_equal [ "tests" ], task.verifier.restore_paths
      assert_equal [ "make verify-prep" ], task.verifier.setup.commands
      assert_same task.config.environment, task.environment

      assert_empty task.config.setup.commands
      assert_empty task.config.verifier.restore_paths
      assert_predicate task.config.verifier.setup, :empty?
    end
  end

  def test_a_task_cannot_override_the_frozen_profile
    with_task_dir("frozen") do |dir|
      dir.join("instruction.md").write("---\noverrides: { cpus: 8 }\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "cannot override the frozen profile (cpus)"
    end
  end

  def test_a_task_may_only_override_verifier_setup
    with_task_dir("grabby") do |dir|
      dir.join("instruction.md").write("---\nverifier:\n  command: bash /cheat.sh\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "verifier.command"
    end
  end

  def test_a_task_cannot_shadow_a_bench_setup_file
    with_task_dir("shadowing") do |dir|
      config = Lemans::Config.new
      config.setup.files = [ [ BenchFixture::ROOT.join("bench.yml"), "tests/test.sh" ] ]
      dir.join("instruction.md").write("---\nsetup:\n  files: [tests/test.sh]\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { Lemans::TaskDefinition.load_from_directory(config, dir) }

      assert_includes error.message, "already ships"
    end
  end

  def test_environment_image_resolution
    with_task_dir("imaged") do |dir|
      config = Lemans::Config.new
      config.environment.image = "ruby:3.4"
      task = Lemans::TaskDefinition.load_from_directory(config, dir)

      assert_predicate task.environment_image, :built?
      assert_equal dir.join("environment"), task.environment_image.context_dir

      FileUtils.rm_rf(dir.join("environment"))
      task = Lemans::TaskDefinition.load_from_directory(config, dir)

      assert_equal "ruby:3.4", task.environment_image.name

      config.environment.image = nil
      shared = dir.parent.join("environment")
      shared.mkpath
      shared.join("Dockerfile").write("FROM scratch\n")
      config.environment.dockerfile = shared.join("Dockerfile")
      task = Lemans::TaskDefinition.load_from_directory(config, dir)

      assert_predicate task.environment_image, :built?
      assert_equal shared, task.environment_image.context_dir

      config.environment.dockerfile = nil
      error = assert_raises(Lemans::ConfigError) { Lemans::TaskDefinition.load_from_directory(config, dir) }

      assert_includes error.message, "no shared image or dockerfile"
    end
  end

  def test_environment_profile_resolution
    with_task_dir("profiled") do |dir|
      config = Lemans::Config.new
      campfire = dir.parent.join("docker/campfire")
      campfire.mkpath
      campfire.join("Dockerfile").write("FROM scratch\n")
      config.environment.profiles["campfire"] = Lemans::Config::Environment::Profile.new(dockerfile: campfire.join("Dockerfile"))
      config.environment.profiles["fizzy"] = Lemans::Config::Environment::Profile.new(image: "ghcr.io/x/fizzy")
      dir.join("instruction.md").write("---\nenvironment: campfire\n---\nGo.\n")

      error = assert_raises(Lemans::ConfigError) { Lemans::TaskDefinition.load_from_directory(config, dir) }

      assert_includes error.message, "mutually exclusive"

      FileUtils.rm_rf(dir.join("environment"))
      task = Lemans::TaskDefinition.load_from_directory(config, dir)

      assert_equal "campfire", task.environment_profile
      assert_predicate task.environment_image, :built?
      assert_equal campfire, task.environment_image.context_dir
      assert_equal "campfire", task.environment_image.slug

      dir.join("instruction.md").write("---\nenvironment: fizzy\n---\nGo.\n")
      task = Lemans::TaskDefinition.load_from_directory(config, dir)

      assert_equal "ghcr.io/x/fizzy", task.environment_image.name

      dir.join("instruction.md").write("---\nenvironment: writebook\n---\nGo.\n")
      error = assert_raises(Lemans::ConfigError) { Lemans::TaskDefinition.load_from_directory(config, dir) }

      assert_includes error.message, "unknown environment writebook — bench.yml declares campfire, fizzy"
    end
  end

  def test_multistep_step_projections
    with_multistep_dir do |dir|
      task = load_task(dir)

      assert_predicate task, :multistep?
      assert_equal 2, task.steps
      refute_predicate task, :final_step?
      assert_raises(ArgumentError) { task.instruction }

      first = task.for_step(1)

      refute_predicate first, :final_step?
      # No indexed tests: the step runs unverified rather than failing.
      refute_predicate first, :verifiable?
      assert_includes first.instruction, "Shared preamble."
      assert_includes first.instruction, "step one"
      refute_includes first.instruction, "step two"

      last = task.for_step(2)

      assert_predicate last, :final_step?
      assert_includes last.instruction, "Shared preamble."
      assert_includes last.instruction, "step two"
      refute_includes last.instruction, "step one"
    end
  end

  def test_a_single_step_task_is_its_own_final_step
    with_task_dir("plain") do |dir|
      task = load_task(dir)

      refute_predicate task, :multistep?
      assert_equal 1, task.steps
      assert_predicate task, :final_step?
    end
  end

  def test_multistep_needs_step_sections
    with_task_dir("flagged") do |dir|
      dir.join("instruction.md").write("---\nmultistep: true\n---\nJust one story.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "single section"
    end
  end

  def test_step_files_ship_under_unindexed_remote_names
    with_multistep_dir do |dir|
      dir.join("verification_test.1.rb").write("checks\n")
      dir.join("solution.1.patch").write("diff\n")
      dir.join("solve.2.sh").write("apply\n")
      task = load_task(dir)

      assert_equal [ "verification_test.rb" ], task.for_step(1).test_files.map(&:last)
      assert_predicate task.for_step(1), :verifiable?
      # The final step is verified as always: the regular tests/ directory.
      assert_equal [ "test.sh" ], task.for_step(2).test_files.map(&:last)
      # Solutions chain, so an indexed final one completes the sequence.
      assert_equal [ "solution.patch" ], task.for_step(1).solution_files.map(&:last)
      assert_equal [ "solve.sh" ], task.for_step(2).solution_files.map(&:last)
      assert_predicate task.for_step(2), :solution?
    end
  end

  def test_a_lone_solution_patch_solves_the_whole_multistep_task_from_step_one
    with_multistep_dir do |dir|
      dir.join("solution.patch").write("diff all\n")
      task = load_task(dir)

      assert_equal [ "solution.patch" ], task.for_step(1).solution_files.map(&:last)
      assert_empty task.for_step(2).solution_files
      refute_predicate task.for_step(1), :solution_applied_earlier?
      assert_predicate task.for_step(2), :solution_applied_earlier?
    end
  end

  def test_a_step_tests_directory_expands
    with_multistep_dir do |dir|
      dir.join("tests.1").mkpath
      dir.join("tests.1/verify").write("#!/bin/sh\n")
      dir.join("solution.1").mkpath
      dir.join("solution.1/solve.sh").write("apply\n")
      task = load_task(dir)

      assert_equal [ "verify" ], task.for_step(1).test_files.map(&:last)
      assert_equal [ "solve.sh" ], task.for_step(1).solution_files.map(&:last)
      assert_empty task.for_step(2).solution_files
    end
  end

  def test_a_shared_tests_directory_ships_its_helpers_with_every_step
    with_multistep_dir do |dir|
      dir.join("tests/helpers.rb").write("module Helpers; end\n")
      dir.join("tests/fixtures").mkpath
      dir.join("tests/fixtures/seed.json").write("{}\n")
      dir.join("tests/verification_test.1.rb").write("step one checks\n")
      dir.join("tests/verification_test.rb").write("final checks\n")
      task = load_task(dir)

      first = task.for_step(1).test_files.to_h { |local, remote| [ remote, local.basename.to_s ] }

      # The helpers ride along, the step's own test takes the unindexed name,
      # and the final step's checks stay out of reach.
      assert_equal({ "helpers.rb" => "helpers.rb", "fixtures/seed.json" => "seed.json",
                     "verification_test.rb" => "verification_test.1.rb" }, first)

      last = task.for_step(2).test_files.to_h { |local, remote| [ remote, local.basename.to_s ] }

      assert_equal({ "helpers.rb" => "helpers.rb", "fixtures/seed.json" => "seed.json", "test.sh" => "test.sh",
                     "verification_test.rb" => "verification_test.rb" }, last)
    end
  end

  def test_a_flat_final_test_rides_with_the_shared_directory
    with_multistep_dir do |dir|
      dir.join("tests/helpers.rb").write("module Helpers; end\n")
      dir.join("verification_test.rb").write("final checks\n")
      dir.join("verification_test.1.rb").write("step one checks\n")
      task = load_task(dir)

      assert_equal %w[helpers.rb test.sh verification_test.rb],
                   task.for_step(2).test_files.map(&:last).sort
      assert_equal "verification_test.rb", task.for_step(2).test_files.to_h { |l, r| [ r, l.basename.to_s ] }.dig("verification_test.rb")
    end
  end

  def test_a_step_without_its_own_test_runs_unverified_despite_shared_helpers
    with_multistep_dir do |dir|
      dir.join("tests/helpers.rb").write("module Helpers; end\n")
      task = load_task(dir)

      assert_empty task.for_step(1).test_files
      refute_predicate task.for_step(1), :verifiable?
      assert_equal %w[helpers.rb test.sh], task.for_step(2).test_files.map(&:last).sort
    end
  end

  def test_indexed_tests_inside_the_shared_directory_are_validated
    with_multistep_dir do |dir|
      dir.join("tests/verification_test.2.rb").write("checks\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "tests/verification_test.2.rb"
      assert_includes error.message, "final verification keeps the unindexed name"
    end

    with_multistep_dir do |dir|
      dir.join("tests/verify.3").write("#!/bin/sh\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "the task has 2 steps"
    end
  end

  def test_indexed_step_files_are_validated
    with_task_dir("stray") do |dir|
      dir.join("verification_test.1.rb").write("checks\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "not multistep"
    end

    with_multistep_dir do |dir|
      dir.join("verification_test.2.rb").write("checks\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "final verification keeps the unindexed name"
    end

    with_multistep_dir do |dir|
      dir.join("solution.1.patch").write("diff\n")
      dir.join("solution.patch").write("diff all\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "one or the other, not both"
    end

    with_multistep_dir do |dir|
      dir.join("solution.3.patch").write("diff\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "the task has 2 steps"
    end
  end

  def test_unclosed_frontmatter
    with_task_dir("broken") do |dir|
      dir.join("instruction.md").write("---\ndescription: broken\nFix it.\n")

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "never closes"
    end
  end

  def test_missing_instruction
    with_task_dir("bare") do |dir|
      dir.join("instruction.md").delete

      error = assert_raises(Lemans::ConfigError) { load_task(dir) }

      assert_includes error.message, "instruction.md is required"
    end
  end
end
