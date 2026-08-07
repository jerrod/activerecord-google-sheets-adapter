if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    skip "/test/"
    enable_coverage :branch
    coverage(:line) { minimum_per_file 95 }
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "activerecord-google-sheets-adapter"
require "minitest/autorun"
require "webmock/minitest"

require_relative "support/fake_sheets_service"

SPREADSHEET_ID = "test-spreadsheet".freeze
