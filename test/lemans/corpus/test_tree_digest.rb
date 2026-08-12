# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class TreeDigestTest < Minitest::Test
  # Without a separator, file `ab` holding `c` and file `a` holding `bc` feed
  # the SHA the same bytes — and a colliding digest reuses the wrong snapshot.
  def test_path_and_contents_cannot_bleed_into_each_other
    refute_equal digest_of("ab" => "c"), digest_of("a" => "bc")
  end

  def test_the_same_tree_digests_the_same
    assert_equal digest_of("a" => "bc"), digest_of("a" => "bc")
  end

  def test_binary_contents_are_read_as_bytes_not_text
    assert_match(/\A[0-9a-f]{64}\z/, digest_of("blob.bin" => (+"\xff\xfe\x00\x01").b))
  end

  private

  def digest_of(files)
    Dir.mktmpdir do |dir|
      files.each { |path, content| File.binwrite(File.join(dir, path), content) }
      break Lemans::Corpus::TreeDigest.call(dir)
    end
  end
end
