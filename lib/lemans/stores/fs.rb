# frozen_string_literal: true

require "pathname"

module Lemans
  module Stores
    # A file-system store (default)
    class FS < Store
      FILENAME = "result.json"

      private attr_reader :root

      def initialize(root)
        super
        @root = Pathname(root)
      end

      def setup
        root.mkpath
      rescue SystemCallError => e
        raise ConfigError, "cannot use runs directory #{root}: #{e.message}"
      end

      def fetch
        root.glob("**/#{FILENAME}").filter_map { to_record(it) }
      end

      def save(result)
        atomic_write(result_dir(result).join(FILENAME), "#{JSON.pretty_generate(result.as_json)}\n")
      rescue SystemCallError, JSON::GeneratorError => e
        # runs_dir unwritable, disk full
        raise ConfigError, "cannot record trial #{result.id}: #{e.message}"
      end

      def save_artifact(result, contents, path:)
        # TODO: contents could be eiher IO (file) or text
      end

      private

      def to_record(json_path)
        data = JSON.parse(json_path.read, symbolize_names: true)

        Result.from_json(data)
      rescue JSON::ParserError, SystemCallError, IOError, Result::IncompatibleError
        nil
      end

      def atomic_write(path, content)
        path.dirname.mkpath
        tmp = path.dirname.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(4)}")
        tmp.write(content)
        tmp.rename(path)
      ensure
        tmp&.delete if tmp&.exist?
      end

      # result.json is stored at <root>/<model-short>/<task-id>
      def result_dir(result)
        root.join(result.model.split("/").last).join(result.id)
      end
    end
  end
end
