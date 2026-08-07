require_relative "fake_sheets_service"

# Shared harness for tests that talk to ActiveRecord through the adapter:
# seeds the fake Sheets backend and opens a google_sheets connection.
class AdapterTestCase < Minitest::Test
  class Contact < ActiveRecord::Base
    self.table_name = "contacts"
  end

  def setup
    @service = FakeSheetsService.new(SPREADSHEET_ID)
    @service.seed("contacts", [
      ["id", "name", "email", "age", "active", "signed_up_on", "last_seen_at", "score"],
      [1, "Ada Lovelace", "ada@example.com", 36, true, "1852-11-27", "2026-08-01 09:00:00", 1.5],
      [2, "Grace Hopper", "grace@example.com", 85, false, "1992-01-01", "2026-08-02 10:30:00", 2],
      [3, "Alan Turing", "", 41, true, "1954-06-07", "2026-08-03 11:45:00", 3.25]
    ])
    @service.register!
    ActiveRecord::Base.establish_connection(
      adapter: "google_sheets",
      spreadsheet_id: SPREADSHEET_ID,
      access_token: "test-token"
    )
    Contact.reset_column_information
  end

  # super runs WebMock's teardown alias, which resets the stub registry and
  # request history between tests.
  def teardown
    ActiveRecord::Base.remove_connection
    super
  end

  def connection
    ActiveRecord::Base.lease_connection
  end
end
