module GoogleSheets
  class UnsupportedStatement < StandardError; end

  # Parses the SQL subset that ActiveRecord generates for simple CRUD:
  # SELECT (columns, COUNT, ORDER BY, LIMIT, OFFSET), INSERT, UPDATE, DELETE,
  # and WHERE trees built from =, !=, <, <=, >, >=, LIKE, IN, IS NULL, AND, OR, NOT.
  class StatementParser
    Select = Struct.new(:table, :projections, :where, :order, :limit, :offset)
    Insert = Struct.new(:table, :columns, :rows)
    Update = Struct.new(:table, :assignments, :where)
    Delete = Struct.new(:table, :where)

    Projection = Struct.new(:kind, :column, :alias_name) # kind: :star, :column, :count, :literal_one
    Predicate = Struct.new(:operator, :column, :value, :children)
    Ordering = Struct.new(:column, :descending)

    Token = Struct.new(:type, :value) # :word, :identifier, :string, :number, :symbol

    def self.parse(sql)
      new(sql).parse
    end

    def initialize(sql)
      @sql = sql
      @tokens = tokenize(sql)
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

    # -- expressions --------------------------------------------------------

    def parse_expression
      node = parse_term
      while take_word("OR")
        node = Predicate.new(operator: :or, children: [node, parse_term])
      end
      node
    end

    def parse_term
      node = parse_factor
      while take_word("AND")
        node = Predicate.new(operator: :and, children: [node, parse_factor])
      end
      node
    end

    def parse_factor
      if take_word("NOT")
        return Predicate.new(operator: :not, children: [parse_factor])
      end
      if peek&.type == :symbol && peek.value == "("
        advance
        node = parse_expression
        expect_symbol(")")
        return node
      end
      parse_comparison
    end

    def parse_comparison
      column = expect_column_reference
      if take_word("IS")
        negated = take_word("NOT")
        expect_word("NULL")
        return Predicate.new(operator: negated ? :not_null : :is_null, column: column)
      end
      negated = take_word("NOT")
      if take_word("IN")
        expect_symbol("(")
        values = parse_literal_list
        expect_symbol(")")
        Predicate.new(operator: negated ? :not_in : :in, column: column, value: values)
      elsif take_word("LIKE")
        Predicate.new(operator: negated ? :not_like : :like, column: column, value: expect_literal)
      elsif negated
        unsupported("expected IN or LIKE after NOT")
      else
        operator = expect_comparison_operator
        Predicate.new(operator: operator, column: column, value: expect_literal)
      end
    end

    def expect_comparison_operator
      token = peek
      unsupported("expected a comparison operator, got #{describe(token)}") unless token&.type == :symbol
      advance
      case token.value
      when "=" then :eq
      when "!=", "<>" then :neq
      when ">" then :gt
      when ">=" then :gte
      when "<" then :lt
      when "<=" then :lte
      else unsupported("unsupported operator #{token.value}")
      end
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

    # -- tokenizer ----------------------------------------------------------

    TOKEN_PATTERN = /\s*(?:
      "((?:[^"]|"")*)"            # 1: double-quoted identifier
      |'((?:[^']|'')*)'           # 2: single-quoted string
      |(-?\d+\.\d+)               # 3: float
      |(-?\d+)                    # 4: integer
      |([A-Za-z_][A-Za-z_0-9]*)   # 5: bare word
      |(<=|>=|!=|<>|[(),=<>*.])   # 6: symbol
    )/x

    def tokenize(sql)
      tokens = []
      scanner = sql.strip
      until scanner.empty?
        match = TOKEN_PATTERN.match(scanner)
        unsupported("cannot tokenize near #{scanner[0, 20].inspect}") if match.nil? || match.begin(0) != 0
        tokens << build_token(match)
        scanner = scanner[match.end(0)..].to_s.lstrip
      end
      tokens
    end

    def build_token(match)
      if match[1]
        Token.new(:identifier, match[1].gsub('""', '"'))
      elsif match[2]
        Token.new(:string, match[2].gsub("''", "'"))
      elsif match[3]
        Token.new(:number, Float(match[3]))
      elsif match[4]
        Token.new(:number, Integer(match[4]))
      elsif match[5]
        Token.new(:word, match[5].upcase)
      else
        Token.new(:symbol, match[6])
      end
    end
  end
end
