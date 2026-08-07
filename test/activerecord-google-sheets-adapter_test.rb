require_relative "test_helper"

class ActiverecordGoogleSheetsAdapterTest < Minitest::Test
  def test_registers_the_google_sheets_adapter
    adapter_class = ActiveRecord::ConnectionAdapters.resolve("google_sheets")
    assert_equal ActiveRecord::ConnectionAdapters::GoogleSheetsAdapter, adapter_class
    assert_equal "GoogleSheets", adapter_class::ADAPTER_NAME
  end
end
