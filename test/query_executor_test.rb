require_relative "test_helper"

require "google_sheets/query_executor"
require "google_sheets/spreadsheet_client"

class QueryExecutorTest < Minitest::Test
  def setup
    @service = FakeSheetsService.new(SPREADSHEET_ID)
    @service.seed("crew", [
      ["id", "name", "ready", "rank"],
      [1, "Ada", "TRUE", 2],
      [2, "Grace", "FALSE", 1],
      [3, "Alan", "TRUE", 3]
    ])
    @service.register!
    client = GoogleSheets::SpreadsheetClient.new(spreadsheet_id: SPREADSHEET_ID, access_token: "token")
    @executor = GoogleSheets::QueryExecutor.new(client)
  end

  def test_select_supports_grouping_negation_and_string_booleans
    result = @executor.execute(%(SELECT "id" FROM "crew" WHERE "ready" = TRUE))
    assert_equal [[1], [3]], result.rows

    result = @executor.execute(%(SELECT "id" FROM "crew" WHERE NOT "name" LIKE 'A%' OR "rank" > 2))
    assert_equal [2, 3], result.rows.flatten.sort
  end

  def test_select_orders_on_precomputed_keys_and_projects_columns
    result = @executor.execute(%(SELECT "name", "rank" FROM "crew" ORDER BY "rank" DESC))
    assert_equal %w[name rank], result.columns
    assert_equal [["Alan", 3], ["Ada", 2], ["Grace", 1]], result.rows
  end

  def test_count_combined_with_other_columns_is_rejected
    error = assert_raises(GoogleSheets::UnsupportedStatement) do
      @executor.execute(%(SELECT COUNT(*), "id" FROM "crew"))
    end
    assert_match(/COUNT cannot be combined/, error.message)
  end

  def test_insert_appends_all_rows_in_one_request_and_returns_the_last_id
    result = @executor.execute(%(INSERT INTO "crew" ("name") VALUES ('Katherine'), ('Annie')))
    assert_equal 2, result.affected_count
    assert_equal 5, result.last_insert_id
    assert_equal [5, "Annie", "", ""], @service.sheets["crew"].last
    assert_requested :post, %r{/values/.*:append}, times: 1
  end

  def test_insert_rejects_unknown_columns
    assert_raises(GoogleSheets::UnsupportedStatement) do
      @executor.execute(%(INSERT INTO "crew" ("callsign") VALUES ('x')))
    end
  end

  def test_update_batches_every_matched_row_and_reports_the_count
    result = @executor.execute(%(UPDATE "crew" SET "rank" = 9 WHERE "ready" = TRUE))
    assert_equal 2, result.affected_count
    assert_equal 9, @service.sheets["crew"][1][3]
    assert_equal 9, @service.sheets["crew"][3][3]
    assert_requested :post, %r{/values:batchUpdate}, times: 1
  end

  def test_delete_removes_matched_rows
    result = @executor.execute(%(DELETE FROM "crew" WHERE "rank" <= 2))
    assert_equal 2, result.affected_count
    assert_equal [["id", "name", "ready", "rank"], [3, "Alan", "TRUE", 3]], @service.sheets["crew"]
  end

  def test_reset_delegates_to_the_client
    @executor.reset
    @service.seed("extra", [["id"]])
    assert_includes @executor.client.sheet_titles, "extra"
  end
end
