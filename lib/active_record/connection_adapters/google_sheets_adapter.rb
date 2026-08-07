require "active_record"
require "active_record/connection_adapters/abstract_adapter"

require "google_sheets/spreadsheet_client"
require "google_sheets/query_executor"
require "active_record/connection_adapters/google_sheets_schema_statements"

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

      include GoogleSheetsSchemaStatements

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

      # -- quoting ------------------------------------------------------------

      def quote_column_name(name)
        self.class.quote_column_name(name)
      end

      def quote_table_name(name)
        self.class.quote_table_name(name)
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
    end
  end
end
