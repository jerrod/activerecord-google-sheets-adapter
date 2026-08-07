module GoogleSheets
  # The WHERE-clause grammar for StatementParser: OR over AND over NOT and
  # parenthesized groups, with =, !=, <, <=, >, >=, LIKE, IN, and IS NULL
  # comparisons at the leaves. Mixed into StatementParser, which supplies the
  # token-cursor helpers (take_word, expect_symbol, expect_literal, ...).
  module PredicateGrammar
    private

    def parse_expression
      node = parse_term
      while take_word("OR")
        node = StatementParser::Predicate.new(operator: :or, children: [node, parse_term])
      end
      node
    end

    def parse_term
      node = parse_factor
      while take_word("AND")
        node = StatementParser::Predicate.new(operator: :and, children: [node, parse_factor])
      end
      node
    end

    def parse_factor
      if take_word("NOT")
        return StatementParser::Predicate.new(operator: :not, children: [parse_factor])
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
        return StatementParser::Predicate.new(operator: negated ? :not_null : :is_null, column: column)
      end
      negated = take_word("NOT")
      if take_word("IN")
        expect_symbol("(")
        values = parse_literal_list
        expect_symbol(")")
        StatementParser::Predicate.new(operator: negated ? :not_in : :in, column: column, value: values)
      elsif take_word("LIKE")
        StatementParser::Predicate.new(operator: negated ? :not_like : :like, column: column, value: expect_literal)
      elsif negated
        unsupported("expected IN or LIKE after NOT")
      else
        operator = expect_comparison_operator
        StatementParser::Predicate.new(operator: operator, column: column, value: expect_literal)
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
  end
end
