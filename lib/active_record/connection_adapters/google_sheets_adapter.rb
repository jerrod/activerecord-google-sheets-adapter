require "active_record"
require "active_record/connection_adapters/abstract_adapter"

require "google_sheets/spreadsheet_client"
require "google_sheets/query_executor"

module ActiveRecord
  module ConnectionAdapters
    # ActiveRecord adapter backed by one Google Spreadsheet.
    # Each sheet is a table. Row 1 holds the column names. Each later row is a record.
    #
    # database.yml:
    #
    #   development:
    #     adapter: google_sheets
    #     spreadsheet_id: 1AbC...
    #     credentials: config/google_service_account.json  # or access_token: ...
    #
    # Constraints, by design of the backing store:
    # - No real transactions. Writes apply immediately; a rollback cannot undo them.
    # - No indexes and no foreign keys. add_index is accepted and ignored.
    # - Concurrent writers can race on generated ids.
    class GoogleSheetsAdapter < AbstractAdapter
      ADAPTER_NAME = "GoogleSheets"

      class << self
        def new_client(config)
          GoogleSheets::SpreadsheetClient.new(
            spreadsheet_id: config.fetch(:spreadsheet_id).to_s,
            credentials: config[:credentials],
            access_token: config[:access_token]
          )
        rescue KeyError
          raise ArgumentError, "google_sheets adapter requires spreadsheet_id in the database configuration"
        end

        def database_exists?(config)
          true
        end

        def quote_column_name(name)
          %("#{name.to_s.gsub('"', '""')}")
        end

        def quote_table_name(name)
          quote_column_name(name)
        end
      end

      def initialize(...)
        super
        @connection_parameters = @config.slice(:spreadsheet_id, :credentials, :access_token)
      end

      # -- capabilities -------------------------------------------------------

      def supports_ddl_transactions? = false

      def supports_savepoints? = false

      def supports_transaction_isolation? = false

      def supports_foreign_keys? = false

      def supports_views? = false

      def supports_indexes_in_create? = false

      def supports_explain? = false

      def supports_count_distinct? = false

      # -- connection lifecycle ----------------------------------------------

      def active?
        connected?
      end

      def disconnect!
        super
        @raw_connection&.reset
        @raw_connection = nil
      end

      def spreadsheet_client # :nodoc:
        query_executor.client
      end

      # -- transactions (no-ops: the backing store has none) ------------------

      def begin_db_transaction
      end

      def commit_db_transaction
      end

      def exec_rollback_db_transaction
      end

      # -- schema -------------------------------------------------------------

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

      # -- quoting ------------------------------------------------------------

      def quote_column_name(name)
        self.class.quote_column_name(name)
      end

      def quote_table_name(name)
        self.class.quote_table_name(name)
      end

      # -- types --------------------------------------------------------------

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

      READ_QUERY = AbstractAdapter.build_read_query_regexp.freeze # :nodoc:

      def write_query?(sql) # :nodoc:
        !READ_QUERY.match?(sql)
      end

      private

      def query_executor
        @raw_connection || (connect! && @raw_connection)
      end

      def default_prepared_statements
        false
      end

      def connect
        @raw_connection = GoogleSheets::QueryExecutor.new(self.class.new_client(@connection_parameters))
      end

      def reconnect
        @raw_connection&.reset
        connect
      end

      def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:, batch:)
        if binds.any?
          raise GoogleSheets::UnsupportedStatement, "the google_sheets adapter does not support prepared statements"
        end
        result = raw_connection.execute(sql)
        notification_payload[:row_count] = result.rows&.length || result.affected_count || 0 if notification_payload
        @last_activity = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result
      end

      def cast_result(raw_result)
        if raw_result.columns
          ActiveRecord::Result.new(raw_result.columns, raw_result.rows)
        elsif raw_result.last_insert_id
          ActiveRecord::Result.new(["id"], [[raw_result.last_insert_id]])
        else
          ActiveRecord::Result.empty
        end
      end

      def affected_rows(raw_result)
        raw_result.affected_count || 0
      end

      def last_inserted_id(result)
        result.rows.dig(0, 0) if result.respond_to?(:rows)
      end

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
