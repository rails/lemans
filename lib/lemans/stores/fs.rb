# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"

module Lemans
  module Stores
    # A file-system store (default)
    class FS < Store
      FILENAME = "result.json"

      private attr_reader :root

      def initialize(root)
        super()
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

      # The file system keeps no index, so filtering happens in memory.
      def query(task: nil, agent: nil, model: nil, tags: nil)
        results = fetch
        results.select! { Array(task).include?(it.task) } if task
        results.select! { it.agent == agent } if agent
        results.select! { it.model == model } if model
        results.select! { Array(tags).intersect?(it.tags) } if tags
        results
      end

      def save(result)
        atomic_write(result_dir(result).join(FILENAME), "#{JSON.pretty_generate(result.as_json)}\n")
      rescue SystemCallError, JSON::GeneratorError => e
        # runs_dir unwritable, disk full
        raise ConfigError, "cannot record trial #{result.id}: #{e.message}"
      end

      def save_artifact(result, contents, path:)
        destination = result_dir(result).join(path)
        if destination.exist?
          warn "lemans: artifact #{path} collides with an existing file and was dropped"
          return
        end

        destination.dirname.mkpath
        contents.is_a?(String) ? destination.write(contents) : IO.copy_stream(contents, destination)
        destination
      rescue SystemCallError => e
        warn "lemans: could not save artifact #{path} for #{result.id}: #{e.message}"
        nil
      end

      private

      def to_record(json_path)
        data = JSON.parse(json_path.read, symbolize_names: true)

        Result.from_json(data)
      rescue JSON::ParserError, SystemCallError, IOError, Result::IncompatibleError
        nil
      end

      # --resume treats any result.json as a finished attempt, so the write must
      # be atomic: a rename is either all there or not there at all.
      def atomic_write(path, content)
        path.dirname.mkpath
        tmp = path.dirname.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(4)}")
        tmp.write(content)
        tmp.rename(path)
      ensure
        tmp&.delete if tmp&.exist?
      end

      # result.json is stored at <root>/<model-short>/<result-id>
      def result_dir(result)
        root.join((result.model || result.agent).to_s.split("/").last, result.id)
      end
    end
  end
end
