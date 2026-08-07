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
    @client.append_rows("crew", [[4, "Katherine"], [5, "Annie"]])
    assert_equal [5, "Annie"], @service.sheets["crew"].last

    @client.update_row("crew", 2, [1, "Ada Lovelace"])
    assert_equal [1, "Ada Lovelace"], @service.sheets["crew"][1]

    @client.update_rows("crew", {3 => [2, "Grace Brewster Hopper"], 4 => [3, "Alan M Turing"]})
    assert_equal [2, "Grace Brewster Hopper"], @service.sheets["crew"][2]
    assert_equal [3, "Alan M Turing"], @service.sheets["crew"][3]
    # 2 = the single-row update above plus this batch; each is one request.
    assert_requested :post, %r{/values:batchUpdate}, times: 2

    @client.delete_rows("crew", [2, 4])
    assert_equal 4, @service.sheets["crew"].length

    @client.delete_rows("crew", [])
    assert_equal 4, @service.sheets["crew"].length
  end

  def test_reads_a_bounded_row_range
    assert_equal [["id", "name"], [1, "Ada"]], @client.read_rows("crew", max_rows: 2)
  end

  def test_rejects_a_malformed_spreadsheet_id
    assert_raises(ArgumentError) do
      GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "../evil", access_token: "token")
    end
  end

  def test_retries_transient_failures_with_backoff
    calls = 0
    stub_request(:get, %r{https://sheets\.googleapis\.com/v4/spreadsheets/flaky}).to_return do
      calls += 1
      (calls < 3) ? {status: 429, headers: {"Retry-After" => "0"}} : {
        status: 200,
        body: JSON.generate("sheets" => []),
        headers: {"Content-Type" => "application/json"}
      }
    end
    client = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "flaky", access_token: "token", retry_base_delay: 0)
    assert_equal [], client.sheet_titles
    assert_equal 3, calls
  end

  def test_gives_up_after_the_retry_budget
    stub_request(:get, %r{https://sheets\.googleapis\.com/v4/spreadsheets/down}).to_return(status: 503)
    client = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "down", access_token: "token", retry_base_delay: 0)
    error = assert_raises(GoogleSheets::RequestError) { client.sheet_titles }
    assert_match(/503/, error.message)
    assert_requested :get, %r{/v4/spreadsheets/down}, times: 3
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

  def test_wraps_http_failures_without_echoing_the_body
    stub_request(:get, %r{https://sheets\.googleapis\.com/v4/spreadsheets/broken}).to_return(
      status: 403,
      body: JSON.generate("error" => {"status" => "PERMISSION_DENIED", "message" => "range 'secrets'!A1 says hunter2"})
    )
    client = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "broken", access_token: "token")
    error = assert_raises(GoogleSheets::RequestError) { client.sheet_titles }
    assert_match(/403 PERMISSION_DENIED/, error.message)
    refute_match(/hunter2/, error.message)

    stub_request(:get, %r{https://sheets\.googleapis\.com/v4/spreadsheets/plain}).to_return(status: 400, body: "not json")
    plain = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: "plain", access_token: "token")
    error = assert_raises(GoogleSheets::RequestError) { plain.sheet_titles }
    assert_match(/HTTP 400/, error.message)
    refute_match(/not json/, error.message)
  end

  def test_reset_clears_cached_sheet_listing
    assert_equal ["crew"], @client.sheet_titles
    @service.seed("extra", [["id"]])
    @client.reset
    assert_equal ["crew", "extra"], @client.sheet_titles.sort
  end
end
