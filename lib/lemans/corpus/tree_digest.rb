# frozen_string_literal: true

require "digest"

module Lemans
  module Corpus
    # A directory's contents reduced to one number. Paths hash alongside
    # contents, and dotfiles are included — glob skips them by default.
    module TreeDigest
      def self.call(dir)
        dir = Pathname(dir)
        sha = Digest::SHA256.new
        dir.glob("**/*", File::FNM_DOTMATCH).sort.each do |entry|
          next unless entry.file?

          sha << entry.relative_path_from(dir).to_s
          sha << entry.read
        end
        sha.hexdigest
      end
    end
  end
end
