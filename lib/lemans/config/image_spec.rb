# frozen_string_literal: true

require "digest"
require "pathname"

module Lemans
  class Config
    # An image, either already published or built from a task's Dockerfile.
    # Built images are named by content digest, so reuse is only ever of the identical thing.
    #
    # A Dockerfile may build on a sibling with `FROM ./Dockerfile`: the two
    # are composed into one multi-stage Dockerfile sharing the directory as
    # build context.
    class ImageSpec
      DEFAULT_DOCKERFILE = "Dockerfile"

      FROM = /\A(?<head>\s*FROM\s+(?:--\S+\s+)*)(?<image>\S+)(?<tail>.*)\z/im
      STAGE_NAME = /\s+AS\s+(?<stage>\S+)\s*\z/i

      attr_reader :reference, :dockerfile_path, :slug, :digest, :dockerfiles, :dockerfile

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

        @dockerfiles = []

        @dockerfile = compose(dockerfile_path) if built?
        # Hashing the reference gives backends one answer to "is this the same image" either way.
        @digest =
          if !built?
            Digest::SHA256.hexdigest(reference.to_s)
          elsif dockerfile_path.basename.to_s == DEFAULT_DOCKERFILE
            TreeDigest.call(context_dir)
          else
            Digest::SHA256.hexdigest("#{TreeDigest.call(context_dir)}:#{dockerfile_path.basename}")
          end
      end

      def built? = !dockerfile_path.nil?

      def composed? = dockerfiles.size > 1

      def context_dir = dockerfile_path&.dirname

      def name
        built? ? "lemans-#{digest[0, 32]}" : reference
      end

      def to_s = name

      private

      def compose(path)
        raise ConfigError, "#{path}: builds on itself through FROM ./ references" if dockerfiles.include?(path)
        raise ConfigError, "no Dockerfile at #{path}" unless path.file?

        dockerfiles.unshift(path)
        lines = path.read.lines
        bases = lines.filter_map { FROM.match(it)&.[](:image) }.select { it.start_with?("./") }.uniq
        return lines.join if bases.empty?

        raise ConfigError, "#{path}: builds on #{bases.join(" and ")} — a Dockerfile may build on one sibling only" if bases.size > 1

        base = bases.first.delete_prefix("./")
        raise ConfigError, "#{path}: FROM #{bases.first} must name a Dockerfile in the same directory" if base.include?("/")

        base_lines = compose(path.dirname.join(base)).lines
        stage = name_last_stage!(base_lines, base)

        # Global ARGs (and parser directives) must stay above every FROM
        first_from = lines.index { FROM.match?(it) }
        preamble = lines[0...first_from]
        body = lines[first_from..].map do |line|
          match = FROM.match(line)
          match && match[:image].start_with?("./") ? "#{match[:head]}#{stage}#{match[:tail]}" : line
        end

        [ *preamble, *base_lines, ("\n" unless base_lines.last&.end_with?("\n")), *body ].compact.join
      end

      def name_last_stage!(lines, base)
        index = lines.rindex { FROM.match?(it) } or raise ConfigError, "#{base}: no FROM to build on"
        line = lines[index]
        return line[STAGE_NAME, :stage] if line.match?(STAGE_NAME)

        stage = "lemans-#{base.downcase.gsub(/[^a-z0-9_.-]/, "-")}"
        lines[index] = "#{line.chomp} AS #{stage}#{"\n" if line.end_with?("\n")}"
        stage
      end
    end
  end
end
