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

          # A NUL between path and contents, or file `ab` holding `c` and file
          # `a` holding `bc` would digest identically; no legal path has a NUL.
          sha << entry.relative_path_from(dir).to_s
          sha << "\0"
          sha << entry.binread
        end
        sha.hexdigest
      end
    end
  end
end
