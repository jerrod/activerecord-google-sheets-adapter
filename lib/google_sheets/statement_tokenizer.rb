module GoogleSheets
  class UnsupportedStatement < StandardError; end

  # Turns a SQL string into the flat token stream StatementParser consumes.
  # Token types: :word (bare keyword, upcased), :identifier (double-quoted),
  # :string (single-quoted), :number, and :symbol.
  class StatementTokenizer
    Token = Struct.new(:type, :value)

    TOKEN_PATTERN = /\s*(?:
      "((?:[^"]|"")*)"            # 1: double-quoted identifier
      |'((?:[^']|'')*)'           # 2: single-quoted string
      |(-?\d+\.\d+)               # 3: float
      |(-?\d+)                    # 4: integer
      |([A-Za-z_][A-Za-z_0-9]*)   # 5: bare word
      |(<=|>=|!=|<>|[(),=<>*.])   # 6: symbol
    )/x

    def self.tokenize(sql)
      tokens = []
      scanner = sql.strip
      until scanner.empty?
        match = TOKEN_PATTERN.match(scanner)
        if match.nil? || match.begin(0) != 0
          raise UnsupportedStatement, "cannot tokenize near #{scanner[0, 20].inspect} (statement: #{sql})"
        end
        tokens << build_token(match)
        scanner = scanner[match.end(0)..].to_s.lstrip
      end
      tokens
    end

    def self.build_token(match)
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
    private_class_method :build_token
  end
end
