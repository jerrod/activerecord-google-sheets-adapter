require_relative "test_helper"

require "google_sheets/statement_parser"

# The grammar is exercised through StatementParser, which mixes it in and
# supplies the token cursor.
class PredicateGrammarTest < Minitest::Test
  Parser = GoogleSheets::StatementParser

  def where_for(condition)
    Parser.parse(%(SELECT * FROM "users" WHERE #{condition})).where
  end

  def test_parses_or_not_in_and_like
    where = Parser.parse(<<~SQL.strip).where
      SELECT * FROM "users" WHERE ("users"."id" IN (1, 2) OR "users"."name" LIKE 'A%') AND "users"."id" NOT IN (9) AND "users"."email" IS NOT NULL AND NOT "users"."name" NOT LIKE 'B%'
    SQL
    grouped, not_in, not_null, negated = flatten_and(where)
    assert_equal :or, grouped.operator
    assert_equal [1, 2], grouped.children.first.value
    assert_equal :like, grouped.children.last.operator
    assert_equal :not_in, not_in.operator
    assert_equal :not_null, not_null.operator
    assert_equal :not, negated.operator
    assert_equal :not_like, negated.children.first.operator
  end

  def test_parses_null_and_boolean_leaves
    assert_equal :is_null, where_for(%("users"."email" IS NULL)).operator
    active = where_for(%("users"."active" = TRUE))
    assert_equal true, active.value
    inactive = where_for(%("users"."active" = FALSE))
    assert_equal false, inactive.value
    null_literal = where_for(%("users"."email" = NULL))
    assert_nil null_literal.value
  end

  def test_parses_comparison_operators
    [["=", :eq], ["!=", :neq], ["<>", :neq], ["<", :lt], ["<=", :lte], [">", :gt], [">=", :gte]].each do |symbol, operator|
      assert_equal operator, where_for(%("users"."age" #{symbol} 30)).operator
    end
  end

  def test_rejects_malformed_predicates
    [
      %("users"."age" NOT BETWEEN 1 AND 2),
      %("users"."age" LIKE),
      %("users"."age" IS 3),
      %("users"."age" ~ 3)
    ].each do |condition|
      assert_raises(GoogleSheets::UnsupportedStatement, condition) { where_for(condition) }
    end
  end

  private

  def flatten_and(node)
    return [node] unless node.operator == :and
    flatten_and(node.children.first) + [node.children.last]
  end
end
