# frozen_string_literal: true

require "test_helper"
require "lemans/cli"

class CLITest < Minitest::Test
  def teardown
    Lemans::Agents.unregister("required-agent")
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
end
