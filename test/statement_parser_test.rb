require_relative "test_helper"

require "google_sheets/statement_parser"

class StatementParserTest < Minitest::Test
  Parser = GoogleSheets::StatementParser

  def test_parses_select_star_with_where_order_limit_offset
    statement = Parser.parse(<<~SQL.strip)
      SELECT "users".* FROM "users" WHERE "users"."age" >= 21 AND "users"."name" = 'Ada' ORDER BY "users"."name" DESC, "users"."id" LIMIT 5 OFFSET 2
    SQL
    assert_equal "users", statement.table
    assert_equal :star, statement.projections.first.kind
    assert_equal :and, statement.where.operator
    left, right = statement.where.children
    assert_equal [:gte, "age", 21], [left.operator, left.column, left.value]
    assert_equal [:eq, "name", "Ada"], [right.operator, right.column, right.value]
    assert_equal [["name", true], ["id", false]], statement.order.map { |o| [o.column, o.descending] }
    assert_equal 5, statement.limit
    assert_equal 2, statement.offset
  end

  def test_parses_column_projections_and_literals
    statement = Parser.parse(%(SELECT "users"."name", "users"."active" FROM "users" WHERE "users"."active" = TRUE AND "users"."email" IS NULL))
    assert_equal %w[name active], statement.projections.map(&:column)
    active, email = statement.where.children
    assert_equal true, active.value
    assert_equal :is_null, email.operator
  end

  def test_parses_or_not_in_and_like
    statement = Parser.parse(<<~SQL.strip)
      SELECT * FROM "users" WHERE ("users"."id" IN (1, 2) OR "users"."name" LIKE 'A%') AND "users"."id" NOT IN (9) AND "users"."email" IS NOT NULL AND NOT "users"."name" NOT LIKE 'B%'
    SQL
    grouped, not_in, not_null, negated = flatten_and(statement.where)
    assert_equal :or, grouped.operator
    assert_equal [1, 2], grouped.children.first.value
    assert_equal :like, grouped.children.last.operator
    assert_equal :not_in, not_in.operator
    assert_equal :not_null, not_null.operator
    assert_equal :not, negated.operator
    assert_equal :not_like, negated.children.first.operator
  end

  def test_parses_count_and_exists_projections
    count = Parser.parse(%(SELECT COUNT(*) FROM "users"))
    assert_equal :count, count.projections.first.kind
    assert_nil count.projections.first.column

    count_column = Parser.parse(%(SELECT COUNT("users"."email") AS "tally" FROM "users"))
    assert_equal "email", count_column.projections.first.column
    assert_equal "tally", count_column.projections.first.alias_name

    exists = Parser.parse(%(SELECT 1 AS one FROM "users" WHERE "users"."id" = 3 LIMIT 1))
    assert_equal :literal_one, exists.projections.first.kind
    assert_equal "one", exists.projections.first.alias_name
  end

  def test_parses_insert_with_multiple_rows
    statement = Parser.parse(<<~SQL.strip)
      INSERT INTO "users" ("name", "age", "active", "score") VALUES ('Ada', 36, TRUE, 1.5), ('Grace', NULL, FALSE, -2)
    SQL
    assert_equal %w[name age active score], statement.columns
    assert_equal ["Ada", 36, true, 1.5], statement.rows.first
    assert_equal ["Grace", nil, false, -2], statement.rows.last
  end

  def test_parses_update_and_delete
    update = Parser.parse(%(UPDATE "users" SET "users"."name" = 'Ada L', "age" = 37 WHERE "users"."id" = 1))
    assert_equal({"name" => "Ada L", "age" => 37}, update.assignments)
    assert_equal :eq, update.where.operator

    delete = Parser.parse(%(DELETE FROM "users" WHERE "users"."id" != 1))
    assert_equal :neq, delete.where.operator
  end

  def test_parses_comparison_operators
    [["<", :lt], ["<=", :lte], [">", :gt], ["<>", :neq]].each do |symbol, operator|
      statement = Parser.parse(%(SELECT * FROM "users" WHERE "users"."age" #{symbol} 30))
      assert_equal operator, statement.where.operator
    end
  end

  def test_parses_bare_identifiers_and_escapes
    statement = Parser.parse(%(SELECT * FROM users WHERE "users"."name" = 'it''s' AND "we""ird" = 1))
    assert_equal "users", statement.table
    assert_equal "it's", statement.where.children.first.value
    assert_equal 'we"ird', statement.where.children.last.column
  end

  def test_rejects_unsupported_sql
    [
      "CREATE TABLE \"users\" (id integer)",
      "SELECT * FROM \"users\" JOIN \"posts\" ON 1 = 1",
      "SELECT SUM(\"users\".\"age\") FROM \"users\"",
      "SELECT * FROM \"users\" WHERE \"users\".\"age\" NOT BETWEEN 1 AND 2",
      "SELECT * FROM \"users\" WHERE \"users\".\"age\" = ?",
      "SELECT * FROM \"users\" WHERE",
      "UPDATE \"users\" SET \"name\" = 'x' extra",
      "SELECT * FROM \"users\" LIMIT 'ten'",
      "INSERT INTO \"users\" (\"name\") VALUES (DEFAULT)"
    ].each do |sql|
      assert_raises(GoogleSheets::UnsupportedStatement, sql) { Parser.parse(sql) }
    end
  end

  private

  def flatten_and(node)
    return [node] unless node.operator == :and
    flatten_and(node.children.first) + [node.children.last]
  end
end
