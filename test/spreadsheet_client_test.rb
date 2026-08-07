require_relative "test_helper"

require "google_sheets/spreadsheet_client"

class SpreadsheetClientTest < Minitest::Test
  def setup
    @service = FakeSheetsService.new(SPREADSHEET_ID)
    @service.seed("crew", [["id", "name"], [1, "Ada"], [2, "Grace"], [3, "Alan"]])
    @service.register!
    @client = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: SPREADSHEET_ID, access_token: "token")
  end

  def test_requires_some_credential
    assert_raises(ArgumentError) { GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "x") }
  end

  def test_lists_sheets_and_reads_rows
    assert_equal ["crew"], @client.sheet_titles
    assert @client.sheet_exists?("crew")
    assert_equal [["id", "name"], [1, "Ada"], [2, "Grace"], [3, "Alan"]], @client.read_rows("crew")
  end

  def test_raises_sheet_not_found_after_a_refresh
    assert_raises(GoogleSheets::SheetNotFound) { @client.read_rows("missing") }
  end

  def test_append_update_and_delete_rows
    @client.append_row("crew", [4, "Katherine"])
    assert_equal [4, "Katherine"], @service.sheets["crew"].last

    @client.update_row("crew", 2, [1, "Ada Lovelace"])
    assert_equal [1, "Ada Lovelace"], @service.sheets["crew"][1]

    @client.delete_rows("crew", [2, 4])
    assert_equal [["id", "name"], [2, "Grace"], [4, "Katherine"]], @service.sheets["crew"]

    @client.delete_rows("crew", [])
    assert_equal 3, @service.sheets["crew"].length
  end

  def test_sheet_management
    @client.add_sheet("gear", ["id", "kind"])
    assert_equal [["id", "kind"]], @service.sheets["gear"]

    @client.rename_sheet("gear", "equipment")
    assert @client.sheet_exists?("equipment")

    @client.update_cell("equipment", 1, 27, "flag")
    assert_equal "flag", @service.sheets["equipment"][0][26]

    @client.delete_column("equipment", 27)
    assert_equal ["id", "kind"], @service.sheets["equipment"][0].compact

    @client.delete_sheet("equipment")
    refute @client.sheet_exists?("equipment")
  end

  def test_quotes_titles_with_apostrophes
    @service.seed("ada's list", [["id"], [1]])
    assert_equal [["id"], [1]], @client.read_rows("ada's list")
  end

  def test_wraps_http_failures
    stub_request(:get, %r{https://sheets\.googleapis\.com/v4/spreadsheets/broken}).to_return(status: 403, body: "denied")
    client = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "broken", access_token: "token")
    error = assert_raises(GoogleSheets::RequestError) { client.sheet_titles }
    assert_match(/403/, error.message)
  end

  def test_reset_clears_cached_sheet_listing
    assert_equal ["crew"], @client.sheet_titles
    @service.seed("extra", [["id"]])
    @client.reset
    assert_equal ["crew", "extra"], @client.sheet_titles.sort
  end
end
