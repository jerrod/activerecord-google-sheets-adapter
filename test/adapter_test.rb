require_relative "test_helper"

class AdapterTest < Minitest::Test
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

  def teardown
    ActiveRecord::Base.remove_connection
  end

  def connection
    ActiveRecord::Base.lease_connection
  end

  # -- schema ----------------------------------------------------------------

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

  def test_reports_adapter_metadata
    assert ActiveRecord::ConnectionAdapters::GoogleSheetsAdapter.database_exists?({})
    assert_equal [], connection.views
    assert_equal ["contacts"], connection.data_sources
    assert connection.data_source_exists?("contacts")
    refute connection.view_exists?("contacts")
    assert_equal [], connection.indexes("contacts")
    assert_equal "integer", connection.native_database_types[:primary_key]
  end

  def test_model_attributes_are_typecast
    contact = Contact.find(1)
    assert_equal 36, contact.age
    assert_equal true, contact.active
    assert_equal Date.new(1852, 11, 27), contact.signed_up_on
    assert_kind_of Time, contact.last_seen_at
  end

  # -- reads -------------------------------------------------------------------

  def test_finds_and_filters_records
    assert_equal "Ada Lovelace", Contact.find(1).name
    assert_equal [2], Contact.where(active: false).pluck(:id)
    assert_equal [1, 2], Contact.where(id: [1, 2]).order(:id).pluck(:id)
    assert_equal [3, 2, 1], Contact.order(id: :desc).pluck(:id)
    assert_equal [2], Contact.order(:id).offset(1).limit(1).pluck(:id)
    assert_equal ["Ada Lovelace", "Alan Turing"], Contact.where("name LIKE 'A%'").order(:name).pluck(:name)
    assert_equal [1, 3], Contact.where.not(id: 2).order(:id).pluck(:id)
    assert_equal [2, 3], Contact.where("age > 40").order(:id).pluck(:id)
    assert_equal [1, 2], Contact.where(active: true).or(Contact.where(id: 2)).order(:id).pluck(:id).first(2)
    assert_equal [1], Contact.where(name: "Ada Lovelace").pluck(:id)
    assert_equal [1, 3], Contact.where(active: true, age: 36..).order(:id).pluck(:id)
    assert_equal [1], Contact.where.not(id: [2, 3]).pluck(:id)
    assert_equal [2], Contact.where("name NOT LIKE 'A%'").pluck(:id)
    assert_equal [2, 3], Contact.where("age >= 41").order(:id).pluck(:id)
    assert_equal [1], Contact.where("age < 41").pluck(:id)
    assert_equal [1, 3], Contact.where("age <= 41").order(:id).pluck(:id)
    assert_equal [2, 3], connection.select_all(%(SELECT "id" FROM "contacts" WHERE NOT "name" LIKE 'A%' OR "score" > 3)).rows.flatten.sort
  end

  def test_compares_string_booleans_loosely
    @service.seed("flags", [["id", "ready"], [1, "TRUE"], [2, "FALSE"]])
    connection.reconnect!
    result = connection.select_all(%(SELECT "id" FROM "flags" WHERE "ready" = TRUE))
    assert_equal [[1]], result.rows
  end

  def test_blank_cells_read_as_nil
    assert_nil Contact.find(3).email
    assert_equal [3], Contact.where(email: nil).pluck(:id)
  end

  def test_count_and_exists
    assert_equal 3, Contact.count
    assert_equal 2, Contact.where(active: true).count
    assert_equal 2, Contact.where.not(email: nil).count(:email)
    assert Contact.exists?(2)
    refute Contact.exists?(99)
  end

  def test_raises_on_unsupported_queries
    assert_raises(ActiveRecord::StatementInvalid) { Contact.joins("JOIN x ON 1=1").to_a }
    assert_raises(ActiveRecord::StatementInvalid) { Contact.sum(:age) }
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.select_all(%(SELECT COUNT(*), "id" FROM "contacts"))
    end
  end

  def test_raises_on_bind_parameters
    bind = ActiveRecord::Relation::QueryAttribute.new("id", 1, ActiveRecord::Type::Integer.new)
    assert_raises(ActiveRecord::StatementInvalid) do
      connection.exec_query(%(SELECT * FROM "contacts" WHERE "id" = $1), "SQL", [bind])
    end
  end

  def test_exec_query_returns_an_empty_result_for_writes
    result = connection.exec_query(%(UPDATE "contacts" SET "age" = 42 WHERE "id" = 3))
    assert_empty result.columns
    assert_equal 42, Contact.find(3).age
  end

  def test_create_with_an_explicit_id_keeps_it
    contact = Contact.create!(id: 50, name: "Annie Easley")
    assert_equal 50, contact.id
    assert_equal 50, @service.sheets["contacts"].last.first
  end

  # -- writes ------------------------------------------------------------------

  def test_create_assigns_the_next_id_and_appends_a_row
    contact = Contact.create!(name: "Katherine Johnson", email: "kj@example.com", age: 101, active: true)
    assert_equal 4, contact.id
    appended = @service.sheets["contacts"].last
    assert_equal [4, "Katherine Johnson", "kj@example.com", 101, true], appended.first(5)
    assert_equal 4, Contact.count
  end

  def test_update_rewrites_the_matching_row
    Contact.find(2).update!(name: "Grace Brewster Hopper", active: true)
    row = @service.sheets["contacts"][2]
    assert_equal [2, "Grace Brewster Hopper", "grace@example.com", 85, true], row.first(5)
    assert_equal 3, Contact.count
  end

  def test_update_all_touches_every_matching_row
    updated = Contact.where(active: true).update_all(active: false)
    assert_equal 2, updated
    assert_equal 0, Contact.where(active: true).count
  end

  def test_destroy_removes_the_row
    Contact.find(1).destroy!
    assert_equal [2, 3], Contact.order(:id).pluck(:id)
    assert_equal 3, @service.sheets["contacts"].length
  end

  def test_delete_all_removes_matching_rows_bottom_up
    deleted = Contact.where(id: [1, 3]).delete_all
    assert_equal 2, deleted
    assert_equal [2], Contact.pluck(:id)
  end

  # -- schema changes ------------------------------------------------------------

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

  # -- misc ----------------------------------------------------------------------

  def test_transactions_are_accepted_as_no_ops
    Contact.transaction { Contact.create!(name: "Annie Easley") }
    assert_equal 4, Contact.count
  end

  def test_connection_reports_active_and_reconnects
    assert_equal 3, Contact.count
    assert connection.active?
    connection.reconnect!
    assert_equal 3, Contact.count
    connection.disconnect!
    assert_equal 3, Contact.count
  end

  def test_requires_spreadsheet_id
    assert_raises(ArgumentError) do
      ActiveRecord::ConnectionAdapters::GoogleSheetsAdapter.new_client({access_token: "t"})
    end
  end
end
