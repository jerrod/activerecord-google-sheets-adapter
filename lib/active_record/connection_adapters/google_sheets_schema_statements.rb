module ActiveRecord
  module ConnectionAdapters
    # Schema surface of the GoogleSheets adapter: sheet listing, header-row
    # columns with inferred types, and the sheet mutations behind migrations.
    module GoogleSheetsSchemaStatements
      NATIVE_DATABASE_TYPES = {
        primary_key: "integer",
        string: "string",
        text: "string",
        integer: "integer",
        bigint: "integer",
        float: "float",
        decimal: "float",
        datetime: "datetime",
        time: "string",
        date: "date",
        boolean: "boolean",
        json: "string"
      }.freeze

      def native_database_types
        NATIVE_DATABASE_TYPES
      end

      def tables
        spreadsheet_client.sheet_titles
      end

      def views
        []
      end

      def data_sources
        tables
      end

      def table_exists?(table_name)
        tables.include?(table_name.to_s)
      end

      def data_source_exists?(name)
        table_exists?(name)
      end

      def view_exists?(view_name)
        false
      end

      def columns(table_name)
        headers, samples = headers_and_samples(table_name.to_s)
        headers.each_with_index.map do |header, index|
          type = infer_type(header, samples.map { |row| row[index] })
          metadata = SqlTypeMetadata.new(sql_type: type.to_s, type: type)
          Column.new(header, ActiveRecord::Type.lookup(type), nil, metadata, header != "id")
        end
      end

      def primary_key(table_name)
        headers, _samples = headers_and_samples(table_name.to_s)
        headers.include?("id") ? "id" : nil
      end

      def indexes(table_name)
        []
      end

      def add_index(table_name, column_name, **options)
        # Sheets has no indexes. Accepted so standard migrations run unchanged.
      end

      def remove_index(table_name, column_name = nil, **options)
      end

      def create_table(table_name, id: :primary_key, primary_key: nil, force: nil, **options)
        table_definition = create_table_definition(table_name)
        table_definition.column(primary_key || "id", :integer) unless id == false
        yield table_definition if block_given?
        headers = table_definition.columns.map { |column| column.name.to_s }.uniq
        drop_table(table_name) if force && table_exists?(table_name)
        spreadsheet_client.add_sheet(table_name.to_s, headers)
      end

      def drop_table(table_name, **options)
        spreadsheet_client.delete_sheet(table_name.to_s)
      end

      def rename_table(table_name, new_name, **options)
        spreadsheet_client.rename_sheet(table_name.to_s, new_name.to_s)
      end

      def add_column(table_name, column_name, type = :string, **options)
        headers, _samples = headers_and_samples(table_name.to_s)
        if headers.include?(column_name.to_s)
          raise ActiveRecord::StatementInvalid, "column #{column_name} already exists in #{table_name}"
        end
        spreadsheet_client.update_cell(table_name.to_s, 1, headers.length + 1, column_name.to_s)
      end

      def remove_column(table_name, column_name, type = nil, **options)
        spreadsheet_client.delete_column(table_name.to_s, column_position(table_name, column_name))
      end

      def rename_column(table_name, column_name, new_column_name)
        position = column_position(table_name, column_name)
        spreadsheet_client.update_cell(table_name.to_s, 1, position, new_column_name.to_s)
      end

      private

      def headers_and_samples(table_name, sample_limit = 50)
        rows = spreadsheet_client.read_rows(table_name, max_rows: sample_limit + 1)
        headers = (rows.first || []).map(&:to_s)
        [headers, rows.drop(1)]
      end

      def column_position(table_name, column_name)
        headers, _samples = headers_and_samples(table_name.to_s)
        index = headers.index(column_name.to_s)
        raise ActiveRecord::StatementInvalid, "no column #{column_name} in #{table_name}" if index.nil?
        index + 1
      end

      DATETIME_PATTERN = /\A\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/
      DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

      def infer_type(header, values)
        return :integer if header == "id"
        present = values.reject { |value| value.nil? || value == "" }
        return :string if present.empty?
        if present.all? { |value| value.is_a?(Integer) }
          :integer
        elsif present.all? { |value| value.is_a?(Numeric) }
          :float
        elsif present.all? { |value| value == true || value == false }
          :boolean
        elsif present.all? { |value| value.is_a?(String) && value.match?(DATETIME_PATTERN) }
          :datetime
        elsif present.all? { |value| value.is_a?(String) && value.match?(DATE_PATTERN) }
          :date
        else
          :string
        end
      end
    end
  end
end
