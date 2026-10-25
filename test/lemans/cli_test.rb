# frozen_string_literal: true

require "test_helper"
require "lemans/cli"

class CLITest < Minitest::Test
  include BenchFixture

  def teardown
    Lemans::Agents.unregister("required-agent")
    Lemans::Environments.unregister("required-backend")
  end

  def test_require
    Dir.mktmpdir do |dir|
      file = File.join(dir, "required_agent.rb")
      File.write(file, <<~RUBY)
        class RequiredAgent < Lemans::Agent
          NAME = "required-agent"
        end
        Lemans::Agents.register(RequiredAgent::NAME, RequiredAgent)
      RUBY

      _, err = capture_io do
        Miniswen.stub(:refresh_registry!, nil) do
          assert_raises(SystemExit) do
            Lemans::CLI.start([ "run", "--bench", BenchFixture::ROOT.to_s, "--require", file, "--task", "none" ])
          end
        end
      end

      assert_includes Lemans::Agents.names, "required-agent"
      assert_includes err, "no matching tasks"
    end
  end

  def test_require_before_the_command
    Dir.mktmpdir do |dir|
      agent = File.join(dir, "required_agent.rb")
      File.write(agent, <<~RUBY)
        class RequiredAgent < Lemans::Agent; end
        Lemans::Agents.register("required-agent", RequiredAgent)
      RUBY
      backend = File.join(dir, "required_backend.rb")
      File.write(backend, <<~RUBY)
        class RequiredBackend < Lemans::Environment; end
        Lemans::Environments.register("required-backend", RequiredBackend)
      RUBY

      _, err = capture_io do
        Miniswen.stub(:refresh_registry!, nil) do
          assert_raises(SystemExit) do
            Lemans::CLI.start([ "-r", agent, "--require=#{backend}", "run", "--bench", BenchFixture::ROOT.to_s,
                                "--backend", "required-backend", "--task", "none" ])
          end
        end
      end

      assert_includes Lemans::Agents.names, "required-agent"
      assert_includes Lemans::Environments.names, "required-backend"
      assert_includes err, "no matching tasks"
    end
  end

  def test_filter_tasks_by_variant
    with_task_dir("varied") do |dir|
      dir.join("instruction.codegraph.md").write("Use the code graph.\n")
      task = Lemans::TaskDefinition.load_from_directory(Lemans::Config.new, dir)
      cli = Lemans::CLI.new

      picked = cli.send(:filter_tasks, [ task ], name: %w[varied varied#codegraph varied])

      assert_equal %w[varied varied#codegraph], picked.map(&:name)
      assert_equal [ "varied" ], cli.send(:filter_tasks, [ task ], tags: nil).map(&:name)
      assert_raises(Lemans::ConfigError) { cli.send(:filter_tasks, [ task ], name: [ "varied#nope" ]) }
    end
  end

  def test_require_for_any_command
    Dir.mktmpdir do |dir|
      plugin = File.join(dir, "required_plugin.rb")
      File.write(plugin, "Lemans::Environments.register(\"required-backend\", Class.new(Lemans::Environment))\n")

      _, err = capture_io { assert_raises(SystemExit) { Lemans::CLI.start([ "report", dir, "-r", plugin ]) } }

      assert_includes Lemans::Environments.names, "required-backend"
      assert_includes err, "no matching results"
    end
  end
end
