require_relative "test_helper"

require "google_sheets/statement_tokenizer"

class StatementTokenizerTest < Minitest::Test
  Tokenizer = GoogleSheets::StatementTokenizer

  def test_tokenizes_every_token_type
    tokens = Tokenizer.tokenize(%(SELECT "users"."name" FROM users WHERE "age" >= -1.5 AND "note" = 'it''s' OR "n" != 2))
    assert_equal [:word, "SELECT"], [tokens[0].type, tokens[0].value]
    assert_equal [:identifier, "users"], [tokens[1].type, tokens[1].value]
    assert_equal [:symbol, "."], [tokens[2].type, tokens[2].value]
    assert_equal [:word, "FROM"], [tokens[4].type, tokens[4].value]
    assert_includes tokens.map { |t| [t.type, t.value] }, [:symbol, ">="]
    assert_includes tokens.map { |t| [t.type, t.value] }, [:number, -1.5]
    assert_includes tokens.map { |t| [t.type, t.value] }, [:string, "it's"]
    assert_includes tokens.map { |t| [t.type, t.value] }, [:symbol, "!="]
    assert_includes tokens.map { |t| [t.type, t.value] }, [:number, 2]
  end

  def test_unescapes_doubled_quotes_in_identifiers
    tokens = Tokenizer.tokenize(%("we""ird"))
    assert_equal 'we"ird', tokens.first.value
  end

  def test_raises_on_untokenizable_input
    error = assert_raises(GoogleSheets::UnsupportedStatement) { Tokenizer.tokenize("SELECT ?") }
    assert_match(/cannot tokenize/, error.message)
  end
end
