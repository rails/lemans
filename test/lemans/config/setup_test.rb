# frozen_string_literal: true

require "test_helper"
require "yaml"

class ConfigSetupTest < Minitest::Test
  ROOT = BenchFixture::ROOT.join("tasks/hello-world")

  def from_config(data, root: ROOT) = Lemans::Config::Setup.from_config(data, root:)

  def test_a_bare_list_is_commands_shorthand
    setup = from_config(["bundle install"])

    assert_equal ["bundle install"], setup.commands
    assert_empty setup.files
  end

  def test_full_form
    setup = from_config({ "commands" => ["bash tests/test.sh"], "files" => ["tests/test.sh"] })

    assert_equal ["bash tests/test.sh"], setup.commands
    assert_equal [[ROOT.join("tests/test.sh"), "tests/test.sh"]], setup.files
  end

  def test_merge_concatenates_without_mutating
    base = from_config({ "commands" => %w[a], "files" => ["tests/test.sh"] })
    extra = from_config(%w[b])
    merged = base.merge(extra)

    assert_equal %w[a b], merged.commands
    assert_equal 1, merged.files.size
    assert_equal %w[a], base.commands
  end

  def test_files_are_confined_and_must_exist
    assert_raises(Lemans::ConfigError) { from_config({ "files" => ["/etc/passwd"] }) }
    assert_raises(Lemans::ConfigError) { from_config({ "files" => ["../evil"] }) }
    assert_raises(Lemans::ConfigError) { from_config({ "files" => ["missing.txt"] }) }
  end

  def test_environment_setup_commands_fold_into_the_setup_section
    Dir.mktmpdir do |dir|
      Pathname(dir).join("bench.yml").write(<<~YAML)
        setup:
          commands: [b]
        environment:
          setup: [a]
      YAML
      config = Lemans::Config.load_file(dir)

      assert_equal %w[a b], config.setup.commands
    end
  end
end
