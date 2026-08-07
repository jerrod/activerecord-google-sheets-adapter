require_relative "statement_parser"

module GoogleSheets
  # Runs parsed statements against a SpreadsheetClient.
  # Row 1 of a sheet holds the column names. Each later row is a record.
  class QueryExecutor
    QueryResult = Struct.new(:columns, :rows, :affected_count, :last_insert_id)

    HEADER_ROW_NUMBER = 1

    attr_reader :client

    def initialize(client)
      @client = client
    end

    def reset
      @client.reset
    end

    def execute(sql)
      statement = StatementParser.parse(sql)
      case statement
      when StatementParser::Select then execute_select(statement)
      when StatementParser::Insert then execute_insert(statement)
      when StatementParser::Update then execute_update(statement)
      when StatementParser::Delete then execute_delete(statement)
      end
    end

    private

    Record = Struct.new(:row_number, :attributes)

    def load_records(table)
      rows = @client.read_rows(table)
      headers = (rows.first || []).map(&:to_s)
      records = rows.drop(1).each_with_index.map do |row, index|
        attributes = headers.each_with_index.to_h { |header, column| [header, normalize(row[column])] }
        Record.new(HEADER_ROW_NUMBER + 1 + index, attributes)
      end
      [headers, records]
    end

    # Sheets returns "" for blank cells inside the used range; treat blank as NULL.
    def normalize(value)
      (value == "") ? nil : value
    end

    # -- SELECT --------------------------------------------------------------

    def execute_select(statement)
      headers, records = load_records(statement.table)
      records = records.select { |record| matches?(record.attributes, statement.where) }
      records = apply_order(records, statement.order)
      records = records.drop(statement.offset) if statement.offset
      records = records.take(statement.limit) if statement.limit
      project(statement.projections, headers, records)
    end

    def project(projections, headers, records)
      if projections.length == 1 && projections.first.kind == :count
        projection = projections.first
        count = if projection.column
          records.count { |record| !record.attributes[projection.column].nil? }
        else
          records.length
        end
        return QueryResult.new(columns: [projection.alias_name], rows: [[count]])
      end

      columns = projections.flat_map do |projection|
        case projection.kind
        when :star then headers
        when :column then [projection.column]
        when :literal_one then [projection.alias_name]
        when :count then raise UnsupportedStatement, "COUNT cannot be combined with other select columns"
        end
      end
      rows = records.map do |record|
        columns.map do |column|
          (projections.any? { |p| p.kind == :literal_one && p.alias_name == column }) ? 1 : record.attributes[column]
        end
      end
      QueryResult.new(columns: columns, rows: rows)
    end

    def apply_order(records, orderings)
      return records if orderings.empty?
      records.sort do |left, right|
        comparison = 0
        orderings.each do |ordering|
          comparison = compare_values(left.attributes[ordering.column], right.attributes[ordering.column])
          comparison = -comparison if ordering.descending
          break unless comparison.zero?
        end
        comparison
      end
    end

    # -- INSERT --------------------------------------------------------------

    def execute_insert(statement)
      headers, records = load_records(statement.table)
      last_insert_id = nil
      statement.rows.each do |values|
        attributes = statement.columns.zip(values).to_h
        if headers.include?("id") && !attributes.key?("id")
          last_insert_id = next_id(records)
          attributes["id"] = last_insert_id
          records << Record.new(nil, attributes)
        elsif attributes.key?("id")
          last_insert_id = attributes["id"]
        end
        unknown = attributes.keys - headers
        raise UnsupportedStatement, "unknown columns #{unknown.inspect} for sheet #{statement.table}" if unknown.any?
        @client.append_row(statement.table, headers.map { |header| write_value(attributes.fetch(header, nil)) })
      end
      QueryResult.new(affected_count: statement.rows.length, last_insert_id: last_insert_id)
    end

    def next_id(records)
      records.map { |record| record.attributes["id"].to_i }.max.to_i + 1
    end

    # -- UPDATE / DELETE -----------------------------------------------------

    def execute_update(statement)
      headers, records = load_records(statement.table)
      matched = records.select { |record| matches?(record.attributes, statement.where) }
      matched.each do |record|
        attributes = record.attributes.merge(statement.assignments)
        @client.update_row(statement.table, record.row_number, headers.map { |header| write_value(attributes[header]) })
      end
      QueryResult.new(affected_count: matched.length)
    end

    def execute_delete(statement)
      _, records = load_records(statement.table)
      matched = records.select { |record| matches?(record.attributes, statement.where) }
      @client.delete_rows(statement.table, matched.map(&:row_number))
      QueryResult.new(affected_count: matched.length)
    end

    # -- predicate evaluation --------------------------------------------------

    def matches?(attributes, predicate)
      return true if predicate.nil?
      case predicate.operator
      when :and then predicate.children.all? { |child| matches?(attributes, child) }
      when :or then predicate.children.any? { |child| matches?(attributes, child) }
      when :not then !matches?(attributes, predicate.children.first)
      when :is_null then attributes[predicate.column].nil?
      when :not_null then !attributes[predicate.column].nil?
      when :in then predicate.value.any? { |value| equal_values?(attributes[predicate.column], value) }
      when :not_in then predicate.value.none? { |value| equal_values?(attributes[predicate.column], value) }
      when :eq then equal_values?(attributes[predicate.column], predicate.value)
      when :neq then !equal_values?(attributes[predicate.column], predicate.value)
      when :like then like?(attributes[predicate.column], predicate.value)
      when :not_like then !like?(attributes[predicate.column], predicate.value)
      when :gt, :gte, :lt, :lte then ordered?(predicate.operator, attributes[predicate.column], predicate.value)
      end
    end

    def ordered?(operator, cell, literal)
      return false if cell.nil? || literal.nil?
      comparison = compare_values(cell, literal)
      case operator
      when :gt then comparison > 0
      when :gte then comparison >= 0
      when :lt then comparison < 0
      when :lte then comparison <= 0
      end
    end

    # Sheets stores what it stores; SQL literals arrive typed. Compare numerically
    # when both sides look numeric, otherwise compare as strings.
    def equal_values?(cell, literal)
      return cell.nil? if literal.nil?
      return false if cell.nil?
      if literal.is_a?(Numeric)
        numeric(cell) ? numeric(cell) == literal : false
      elsif [true, false].include?(literal)
        boolean(cell) == literal
      else
        cell.to_s == literal.to_s
      end
    end

    def compare_values(left, right)
      return 0 if left.nil? && right.nil?
      return -1 if left.nil?
      return 1 if right.nil?
      left_number = numeric(left)
      right_number = numeric(right)
      if left_number && right_number
        left_number <=> right_number
      else
        left.to_s <=> right.to_s
      end
    end

    def like?(cell, pattern)
      return false if cell.nil? || pattern.nil?
      regex = Regexp.new("\\A#{Regexp.escape(pattern.to_s).gsub("%", ".*").tr("_", ".")}\\z", Regexp::IGNORECASE)
      regex.match?(cell.to_s)
    end

    def numeric(value)
      case value
      when Numeric then value
      when String then Float(value, exception: false)
      end
    end

    def boolean(value)
      case value
      when true, false then value
      when String then value.casecmp?("true")
      end
    end

    def write_value(value)
      value.nil? ? "" : value
    end
  end
end
