require "json"
require "net/http"
require "uri"

require_relative "service_account_credentials"

module GoogleSheets
  class RequestError < StandardError; end
  class SheetNotFound < StandardError; end

  # Thin HTTP client for the Google Sheets v4 REST API.
  # One spreadsheet is the database. Each sheet is a table.
  class SpreadsheetClient
    BASE_URL = "https://sheets.googleapis.com/v4/spreadsheets".freeze

    attr_reader :spreadsheet_id

    def initialize(spreadsheet_id:, credentials: nil, access_token: nil)
      @spreadsheet_id = spreadsheet_id
      @static_token = access_token
      @credentials = credentials && ServiceAccountCredentials.new(credentials)
      if @static_token.nil? && @credentials.nil?
        raise ArgumentError, "supply credentials (a service-account key path or hash) or access_token"
      end
      @sheet_ids = nil
    end

    def reset
      @sheet_ids = nil
      @credentials&.reset
    end

    def sheet_titles
      sheet_ids.keys
    end

    def sheet_exists?(title)
      sheet_ids.key?(title)
    end

    # Returns every populated row, header row included, as an array of arrays.
    def read_rows(title)
      assert_sheet!(title)
      response = get("/values/#{escaped_range(title)}", "valueRenderOption" => "UNFORMATTED_VALUE")
      response["values"] || []
    end

    def append_row(title, values)
      assert_sheet!(title)
      post("/values/#{escaped_range(title)}:append", {"values" => [values]}, "valueInputOption" => "RAW")
    end

    # row_number is 1-based, as shown in the Sheets UI.
    def update_row(title, row_number, values)
      assert_sheet!(title)
      range = "#{quoted_title(title)}!A#{row_number}"
      put("/values/#{URI.encode_uri_component(range)}", {"range" => range, "values" => [values]}, "valueInputOption" => "RAW")
    end

    def update_cell(title, row_number, column_number, value)
      assert_sheet!(title)
      range = "#{quoted_title(title)}!#{column_letter(column_number)}#{row_number}"
      put("/values/#{URI.encode_uri_component(range)}", {"range" => range, "values" => [[value]]}, "valueInputOption" => "RAW")
    end

    def delete_rows(title, row_numbers)
      return if row_numbers.empty?
      requests = row_numbers.sort.reverse.map do |row_number|
        {"deleteDimension" => {"range" => {
          "sheetId" => sheet_id!(title), "dimension" => "ROWS",
          "startIndex" => row_number - 1, "endIndex" => row_number
        }}}
      end
      batch_update(requests)
    end

    def delete_column(title, column_number)
      batch_update([{"deleteDimension" => {"range" => {
        "sheetId" => sheet_id!(title), "dimension" => "COLUMNS",
        "startIndex" => column_number - 1, "endIndex" => column_number
      }}}])
    end

    def add_sheet(title, headers)
      batch_update([{"addSheet" => {"properties" => {"title" => title}}}])
      @sheet_ids = nil
      update_row(title, 1, headers)
    end

    def delete_sheet(title)
      batch_update([{"deleteSheet" => {"sheetId" => sheet_id!(title)}}])
      @sheet_ids = nil
    end

    def rename_sheet(title, new_title)
      batch_update([{"updateSheetProperties" => {
        "properties" => {"sheetId" => sheet_id!(title), "title" => new_title},
        "fields" => "title"
      }}])
      @sheet_ids = nil
    end

    private

    def sheet_ids
      @sheet_ids ||= begin
        response = get("", "fields" => "sheets.properties(sheetId,title)")
        (response["sheets"] || []).to_h do |sheet|
          properties = sheet.fetch("properties")
          [properties.fetch("title"), properties.fetch("sheetId")]
        end
      end
    end

    def sheet_id!(title)
      assert_sheet!(title)
      sheet_ids.fetch(title)
    end

    def assert_sheet!(title)
      return if sheet_exists?(title)
      @sheet_ids = nil
      raise SheetNotFound, "no sheet named #{title.inspect}" unless sheet_exists?(title)
    end

    def batch_update(requests)
      post(":batchUpdate", {"requests" => requests})
    end

    def escaped_range(title)
      URI.encode_uri_component(quoted_title(title))
    end

    def quoted_title(title)
      "'#{title.gsub("'", "''")}'"
    end

    def column_letter(column_number)
      letters = +""
      while column_number > 0
        column_number, remainder = (column_number - 1).divmod(26)
        letters.prepend((remainder + 65).chr)
      end
      letters
    end

    def get(path, params = {})
      request(Net::HTTP::Get, path, nil, params)
    end

    def post(path, body, params = {})
      request(Net::HTTP::Post, path, body, params)
    end

    def put(path, body, params = {})
      request(Net::HTTP::Put, path, body, params)
    end

    def request(method_class, path, body, params)
      uri = URI("#{BASE_URL}/#{@spreadsheet_id}#{path}")
      uri.query = URI.encode_www_form(params) unless params.empty?
      http_request = method_class.new(uri)
      http_request["Authorization"] = "Bearer #{token}"
      if body
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(http_request) }
      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError, "#{method_class::METHOD} #{uri.path} failed (#{response.code}): #{response.body}"
      end
      (response.body.nil? || response.body.empty?) ? {} : JSON.parse(response.body)
    end

    def token
      @static_token || @credentials.access_token
    end
  end
end
