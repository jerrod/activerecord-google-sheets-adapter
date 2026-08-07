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
    SPREADSHEET_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/
    RETRYABLE_STATUSES = %w[429 500 502 503].freeze
    MAXIMUM_ATTEMPTS = 3

    attr_reader :spreadsheet_id

    def initialize(spreadsheet_id:, credentials: nil, access_token: nil, retry_base_delay: 0.5)
      unless SPREADSHEET_ID_PATTERN.match?(spreadsheet_id.to_s)
        raise ArgumentError, "spreadsheet_id must contain only letters, digits, hyphen, and underscore"
      end
      @spreadsheet_id = spreadsheet_id
      @static_token = access_token
      @credentials = credentials && ServiceAccountCredentials.new(credentials)
      if @static_token.nil? && @credentials.nil?
        raise ArgumentError, "supply credentials (a service-account key path or hash) or access_token"
      end
      @retry_base_delay = retry_base_delay
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

    # Returns populated rows, header row included, as an array of arrays.
    # max_rows bounds the read to the first N rows so schema introspection
    # does not download the whole sheet. Date-typed cells arrive as the
    # sheet's displayed string, not as a serial number.
    def read_rows(title, max_rows: nil)
      assert_sheet!(title)
      range = max_rows ? "#{quoted_title(title)}!1:#{max_rows}" : quoted_title(title)
      response = get(
        "/values/#{URI.encode_uri_component(range)}",
        "valueRenderOption" => "UNFORMATTED_VALUE",
        "dateTimeRenderOption" => "FORMATTED_STRING"
      )
      response["values"] || []
    end

    # Appends every row in one request. rows is an array of row-value arrays.
    def append_rows(title, rows)
      assert_sheet!(title)
      post("/values/#{escaped_range(title)}:append", {"values" => rows}, "valueInputOption" => "RAW")
    end

    # Rewrites many rows in one request. rows_by_number maps a 1-based row
    # number (as shown in the Sheets UI) to its full row values.
    def update_rows(title, rows_by_number)
      assert_sheet!(title)
      data = rows_by_number.map do |row_number, values|
        {"range" => "#{quoted_title(title)}!A#{row_number}", "values" => [values]}
      end
      post("/values:batchUpdate", {"valueInputOption" => "RAW", "data" => data})
    end

    def update_row(title, row_number, values)
      update_rows(title, {row_number => values})
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
      response = batch_update([{"addSheet" => {"properties" => {"title" => title}}}])
      properties = response.dig("replies", 0, "addSheet", "properties")
      if properties && @sheet_ids
        @sheet_ids[properties.fetch("title")] = properties.fetch("sheetId")
      else
        @sheet_ids = nil
      end
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
      response = nil
      MAXIMUM_ATTEMPTS.times do |attempt|
        response = perform(method_class, uri, body)
        break unless RETRYABLE_STATUSES.include?(response.code) && attempt < MAXIMUM_ATTEMPTS - 1
        sleep(retry_delay(response, attempt))
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise RequestError, "#{method_class::METHOD} #{uri.path} failed: #{error_summary(response)}"
      end
      (response.body.nil? || response.body.empty?) ? {} : JSON.parse(response.body)
    end

    def perform(method_class, uri, body)
      http_request = method_class.new(uri)
      http_request["Authorization"] = "Bearer #{token}"
      if body
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(http_request) }
    end

    def retry_delay(response, attempt)
      explicit = response["Retry-After"]
      explicit ? explicit.to_f : @retry_base_delay * (2**attempt)
    end

    # Never echoes the response body: on a 4xx it can carry sheet titles,
    # ranges, and cell values, which must stay out of logs and error trackers.
    def error_summary(response)
      payload = JSON.parse(response.body.to_s)
      ["HTTP", response.code, payload.dig("error", "status")].compact.join(" ")
    rescue JSON::ParserError
      "HTTP #{response.code}"
    end

    def token
      @static_token || @credentials.access_token
    end
  end
end
