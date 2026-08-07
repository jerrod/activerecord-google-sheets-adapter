require_relative "test_helper"
require_relative "support/adapter_test_case"

class GoogleSheetsSchemaStatementsTest < AdapterTestCase
  def test_reports_tables_and_columns_with_inferred_types
    assert_equal ["contacts"], connection.tables
    assert connection.table_exists?("contacts")
    refute connection.table_exists?("missing")
    assert_equal "id", connection.primary_key("contacts")

    types = connection.columns("contacts").to_h { |column| [column.name, column.type] }
    assert_equal :integer, types["id"]
    assert_equal :string, types["name"]
    assert_equal :integer, types["age"]
    assert_equal :boolean, types["active"]
    assert_equal :date, types["signed_up_on"]
    assert_equal :datetime, types["last_seen_at"]
    assert_equal :float, types["score"]
  end

  def test_schema_reads_are_bounded_to_a_sample
    connection.columns("contacts")
    assert_requested :get, %r{/values/.*contacts.*1:51}
  end

  def test_create_table_drop_table_and_column_management
    connection.create_table("projects") do |t|
      t.string :title
      t.integer :budget
    end
    assert_equal ["id", "title", "budget"], @service.sheets["projects"].first

    connection.add_column("projects", :status, :string)
    assert_equal ["id", "title", "budget", "status"], @service.sheets["projects"].first
    assert_raises(ActiveRecord::StatementInvalid) { connection.add_column("projects", :status, :string) }

    connection.rename_column("projects", :status, :phase)
    assert_equal ["id", "title", "budget", "phase"], @service.sheets["projects"].first

    connection.remove_column("projects", :budget)
    assert_equal ["id", "title", "phase"], @service.sheets["projects"].first
    assert_raises(ActiveRecord::StatementInvalid) { connection.remove_column("projects", :missing) }

    connection.add_index("projects", :title)
    connection.remove_index("projects", :title)

    connection.rename_table("projects", "engagements")
    assert connection.table_exists?("engagements")

    connection.create_table("engagements", force: true) { |t| t.string :title }
    assert_equal ["id", "title"], @service.sheets["engagements"].first

    connection.drop_table("engagements")
    refute connection.table_exists?("engagements")
  end

  def test_create_table_without_id_and_composite_headers
    connection.create_table("settings", id: false) do |t|
      t.string :key
      t.string :value
    end
    assert_equal ["key", "value"], @service.sheets["settings"].first
    assert_nil connection.primary_key("settings")
  end
end
