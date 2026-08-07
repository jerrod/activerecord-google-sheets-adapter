require_relative "statement_tokenizer"
require_relative "predicate_grammar"

module GoogleSheets
  # Parses the SQL subset that ActiveRecord generates for simple CRUD:
  # SELECT (columns, COUNT, ORDER BY, LIMIT, OFFSET), INSERT, UPDATE, DELETE,
  # and WHERE trees built from =, !=, <, <=, >, >=, LIKE, IN, IS NULL, AND, OR, NOT.
  class StatementParser
    include PredicateGrammar

    Select = Struct.new(:table, :projections, :where, :order, :limit, :offset)
    Insert = Struct.new(:table, :columns, :rows)
    Update = Struct.new(:table, :assignments, :where)
    Delete = Struct.new(:table, :where)

    Projection = Struct.new(:kind, :column, :alias_name) # kind: :star, :column, :count, :literal_one
    Predicate = Struct.new(:operator, :column, :value, :children)
    Ordering = Struct.new(:column, :descending)

    def self.parse(sql)
      new(sql).parse
    end

    def initialize(sql)
      @sql = sql
      @tokens = StatementTokenizer.tokenize(sql)
      @position = 0
    end

    def parse
      case peek_word
      when "SELECT" then parse_select
      when "INSERT" then parse_insert
      when "UPDATE" then parse_update
      when "DELETE" then parse_delete
      else unsupported("statement must be SELECT, INSERT, UPDATE, or DELETE")
      end
    end

    private

    # -- statements ---------------------------------------------------------

    def parse_select
      expect_word("SELECT")
      projections = parse_projections
      expect_word("FROM")
      table = expect_identifier
      where = take_word("WHERE") ? parse_expression : nil
      order = parse_order
      limit = take_word("LIMIT") ? expect_number : nil
      offset = take_word("OFFSET") ? expect_number : nil
      expect_end
      Select.new(table:, projections:, where:, order:, limit:, offset:)
    end

    def parse_insert
      expect_word("INSERT")
      expect_word("INTO")
      table = expect_identifier
      expect_symbol("(")
      columns = parse_identifier_list
      expect_symbol(")")
      expect_word("VALUES")
      rows = []
      loop do
        expect_symbol("(")
        rows << parse_literal_list
        expect_symbol(")")
        break unless take_symbol(",")
      end
      expect_end
      Insert.new(table:, columns:, rows:)
    end

    def parse_update
      expect_word("UPDATE")
      table = expect_identifier
      expect_word("SET")
      assignments = {}
      loop do
        column = expect_column_reference
        expect_symbol("=")
        assignments[column] = expect_literal
        break unless take_symbol(",")
      end
      where = take_word("WHERE") ? parse_expression : nil
      expect_end
      Update.new(table:, assignments:, where:)
    end

    def parse_delete
      expect_word("DELETE")
      expect_word("FROM")
      table = expect_identifier
      where = take_word("WHERE") ? parse_expression : nil
      expect_end
      Delete.new(table:, where:)
    end

    # -- clauses ------------------------------------------------------------

    def parse_projections
      projections = []
      loop do
        projections << parse_projection
        break unless take_symbol(",")
      end
      projections
    end

    def parse_projection
      if take_symbol("*")
        Projection.new(kind: :star)
      elsif take_word("COUNT")
        expect_symbol("(")
        column = take_symbol("*") ? nil : expect_column_reference
        expect_symbol(")")
        alias_name = take_word("AS") ? expect_identifier : "count"
        Projection.new(kind: :count, column: column, alias_name: alias_name)
      elsif peek&.type == :number && peek.value == 1
        advance
        alias_name = take_word("AS") ? expect_identifier : "one"
        Projection.new(kind: :literal_one, alias_name: alias_name)
      elsif peek&.type == :identifier
        table_or_column = advance.value
        if take_symbol(".")
          return Projection.new(kind: :star) if take_symbol("*")
          Projection.new(kind: :column, column: expect_identifier)
        else
          Projection.new(kind: :column, column: table_or_column)
        end
      else
        unsupported("cannot parse select list at #{describe(peek)}")
      end
    end

    def parse_order
      return [] unless take_word("ORDER")
      expect_word("BY")
      orderings = []
      loop do
        column = expect_column_reference
        descending = if take_word("DESC")
          true
        else
          take_word("ASC")
          false
        end
        orderings << Ordering.new(column:, descending:)
        break unless take_symbol(",")
      end
      orderings
    end

    # -- token helpers ------------------------------------------------------

    def parse_identifier_list
      identifiers = []
      loop do
        identifiers << expect_identifier
        break unless take_symbol(",")
      end
      identifiers
    end

    def parse_literal_list
      literals = []
      loop do
        literals << expect_literal
        break unless take_symbol(",")
      end
      literals
    end

    # Accepts "column" or "table"."column" and returns the column name.
    def expect_column_reference
      name = expect_identifier
      take_symbol(".") ? expect_identifier : name
    end

    def expect_literal
      token = peek
      case token&.type
      when :string, :number then advance.value
      when :word
        case token.value
        when "NULL" then advance && nil
        when "TRUE" then advance && true
        when "FALSE" then advance && false
        else unsupported("expected a literal, got #{describe(token)}")
        end
      else
        unsupported("expected a literal, got #{describe(token)}")
      end
    end

    def expect_identifier
      token = peek
      if token.nil? || (token.type != :identifier && token.type != :word)
        unsupported("expected an identifier, got #{describe(token)}")
      end
      advance
      (token.type == :word) ? token.value.downcase : token.value
    end

    def expect_number
      token = peek
      unsupported("expected a number, got #{describe(token)}") unless token&.type == :number
      advance.value
    end

    def expect_word(word)
      unsupported("expected #{word}, got #{describe(peek)}") unless take_word(word)
      true
    end

    def take_word(word)
      if peek&.type == :word && peek.value == word
        advance
        true
      else
        false
      end
    end

    def peek_word
      (peek&.type == :word) ? peek.value : nil
    end

    def expect_symbol(symbol)
      unsupported("expected #{symbol}, got #{describe(peek)}") unless take_symbol(symbol)
    end

    def take_symbol(symbol)
      if peek&.type == :symbol && peek.value == symbol
        advance
        true
      else
        false
      end
    end

    def expect_end
      unsupported("unexpected trailing input at #{describe(peek)}") if peek
    end

    def peek
      @tokens[@position]
    end

    def advance
      token = @tokens[@position]
      @position += 1
      token
    end

    def describe(token)
      token ? "#{token.type} #{token.value.inspect}" : "end of statement"
    end

    def unsupported(message)
      raise UnsupportedStatement, "#{message} — the google_sheets adapter supports simple CRUD SQL only (statement: #{@sql})"
    end
  end
end
