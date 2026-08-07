# activerecord-google-sheets-adapter

An ActiveRecord connection adapter that uses one Google Spreadsheet as a database. Each sheet is a table. Row 1 holds the column names. Each later row is a record.

## Install

Add the gem to your Rails application's Gemfile:

```ruby
gem "activerecord-google-sheets-adapter"
```

## Configure

Point `config/database.yml` at a spreadsheet:

```yaml
development:
  adapter: google_sheets
  spreadsheet_id: 1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789
  credentials: config/google_service_account.json
```

`credentials` is the path to a Google service-account key file (JSON). Share the spreadsheet with the service account's `client_email`, with editor access. For a quick local session you can pass `access_token` instead of `credentials` (for example, a token from `gcloud auth print-access-token`).

## Use

Models work the way they always do:

```ruby
class Contact < ApplicationRecord
end

Contact.create!(name: "Ada Lovelace", email: "ada@example.com")
Contact.where(active: true).order(:name).limit(10)
Contact.find(1).update!(email: "ada@lovelace.example")
Contact.where("name LIKE 'A%'").count
```

Migrations work too. `create_table` adds a sheet with a header row, `add_column` appends a header cell, and `drop_table` deletes the sheet:

```ruby
class CreateContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :contacts do |t|
      t.string :name
      t.string :email
      t.boolean :active
    end
  end
end
```

## How it maps

| SQL concept | Sheets concept |
|---|---|
| database | one spreadsheet (`spreadsheet_id`) |
| table | one sheet (tab) |
| column | header cell in row 1 |
| record | one row, from row 2 down |
| primary key | an `id` column; the adapter assigns `max(id) + 1` on insert |

The adapter infers each column type from the data in the first 50 rows, which it reads with one bounded request. Records the adapter writes store dates and datetimes as ISO strings. A date-typed cell a human entered reads back as the sheet's displayed text. It detects integers, floats, booleans, `YYYY-MM-DD` dates, and datetime strings. Everything else reads as a string. Declare `attribute :premium, :decimal` in a model when you need a specific cast. A blank cell reads as `NULL`.

## Supported queries

The adapter executes the SQL that ActiveRecord generates for simple CRUD: `SELECT` with `WHERE`, `ORDER BY`, `LIMIT`, `OFFSET`, and `COUNT`, plus `INSERT`, `UPDATE`, and `DELETE`. Predicates can use `=`, `!=`, `<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `IS NULL`, `AND`, `OR`, and `NOT`. Anything else — joins, subqueries, `GROUP BY`, aggregates other than count — raises `ActiveRecord::StatementInvalid` with a clear message. Filtering and sorting happen in Ruby after the adapter reads the sheet, because Sheets has no query engine.

## Limits to know about

- **No transactions.** `Model.transaction` blocks run, but every write applies immediately and a rollback cannot undo it.
- **No uniqueness or foreign-key enforcement.** The adapter accepts `add_index` and ignores it.
- **Concurrent writers can race.** Two processes that insert at the same time can both compute the same next id.
- **Every query reads the whole sheet.** This is fine for hundreds or a few thousand rows, not for millions.
- **The Sheets API has quotas.** Heavy traffic gets rate limited by Google.

This adapter is a good fit for prototypes, internal tools, and datasets a human also edits in the Sheets UI. It is not a replacement for a real database.

## Development

```
bin/setup      # install dependencies
bin/test       # run the test suite
bin/coverage   # run the suite with per-file coverage enforcement
bin/lint       # standardrb
```

Tests stub the Google Sheets REST API at the HTTP boundary with WebMock. The suite needs no network access and no real spreadsheet.

## License

MIT
