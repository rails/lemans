# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "securerandom"

module Lemans
  module Stores
    # A file-system store (default)
    class FS < Store
      FILENAME = "result.json"

      private attr_reader :root, :filterer

      def initialize(root, filterer: nil)
        super()
        @root = Pathname(root)
        @filterer = filterer
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
      def query(task: nil, agent: nil, model: nil, tags: nil, metadata: nil)
        results = fetch
        results.select! { Array(task).include?(it.task) } if task
        results.select! { it.agent == agent } if agent
        results.select! { it.model == model } if model
        results.select! { Array(tags).intersect?(it.tags) } if tags
        results.select! { |result| metadata.all? { |key, value| result.metadata.transform_keys(&:to_s)[key].to_s == value } } if metadata
        results
      end

      RESULT_ID = /\A(?<task>.+)__[A-Za-z0-9]{7}\z/

      def unreadable
        root.glob("**/#{FILENAME}").filter_map do |path|
          next if to_record(path)

          id = path.dirname.basename.to_s
          Result.new(task: RESULT_ID.match(id)&.[](:task), agent: nil, model: nil, id:)
        end
      end

      def delete(result)
        dir = result_dir(result)
        return unless dir.directory?

        FileUtils.remove_entry(dir.to_s)
        prune_empty_parents(dir.parent)
        dir
      rescue SystemCallError => e
        warn "lemans: could not delete #{result.id}: #{e.message}"
        nil
      end

      def save(result)
        atomic_write(result_dir(result).join(FILENAME), filtered("#{JSON.pretty_generate(result.as_json)}\n"))
      rescue SystemCallError, JSON::GeneratorError => e
        # runs_dir unwritable, disk full
        raise ConfigError, "cannot record trial #{result.id}: #{e.message}"
      end

      def save_artifact(result, contents, path:, force: false)
        destination = result_dir(result).join(path)
        if destination.exist? && !force
          warn "lemans: artifact #{path} collides with an existing file and was dropped"
          return
        end

        destination.dirname.mkpath
        contents.is_a?(String) ? destination.write(filtered(contents)) : copy_filtered(contents, destination)
        destination
      rescue SystemCallError => e
        warn "lemans: could not save artifact #{path} for #{result.id}: #{e.message}"
        nil
      end

      def read_artifact(result, path)
        file = result_dir(result).join(path)
        file.read if file.file?
      end

      def artifacts(result)
        dir = result_dir(result)
        return [] unless dir.directory?

        dir.glob("**/*").select(&:file?).map { it.relative_path_from(dir).to_s }.sort
      end

      private

      def filtered(text) = filterer ? filterer.filter(text) : text

      # Secrets never span lines, so filtering line by line keeps memory
      # constant without a plain-text copy ever touching the disk.
      def copy_filtered(contents, destination)
        return IO.copy_stream(contents, destination) unless filterer

        destination.open("wb") do |file|
          contents.each_line { file.write(filterer.filter(it)) }
        end
      end

      def prune_empty_parents(dir)
        while dir != root && dir.children.empty?
          dir.rmdir
          dir = dir.parent
        end
      rescue SystemCallError
        nil
      end

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

      # result.json is stored at <root>/<model-short>/<result-id>; a tree
      # arranged by hand (runs grouped under batch directories) is searched
      # for the id instead.
      def result_dir(result)
        canonical = root.join((result.model || result.agent).to_s.split("/").last.to_s.tr("#", "-"), result.id)
        return canonical if canonical.directory?

        root.glob("**/#{result.id}").find(&:directory?) || canonical
      end
    end
  end
end
