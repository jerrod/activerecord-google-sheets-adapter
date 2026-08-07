require "active_record"

require_relative "google_sheets/version"

ActiveRecord::ConnectionAdapters.register(
  "google_sheets",
  "ActiveRecord::ConnectionAdapters::GoogleSheetsAdapter",
  "active_record/connection_adapters/google_sheets_adapter"
)
