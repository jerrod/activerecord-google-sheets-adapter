require_relative "test_helper"

class VersionTest < Minitest::Test
  def test_version_is_a_semantic_version
    assert_match(/\A\d+\.\d+\.\d+\z/, GoogleSheets::VERSION)
  end
end
