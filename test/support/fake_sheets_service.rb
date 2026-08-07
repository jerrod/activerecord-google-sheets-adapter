require "json"
require "webmock"

# In-memory stand-in for the Google Sheets v4 REST API, wired up through WebMock.
# Tests mock at the HTTP boundary only; every adapter layer above runs for real.
class FakeSheetsService
  include WebMock::API

  attr_reader :sheets

  def initialize(spreadsheet_id)
    @spreadsheet_id = spreadsheet_id
    @sheets = {}
    @sheet_ids = {}
    @next_sheet_id = 100
  end

  def seed(title, rows)
    @sheets[title] = rows.map(&:dup)
    @sheet_ids[title] = (@next_sheet_id += 1)
  end

  def register!
    base = %r{\Ahttps://sheets\.googleapis\.com/v4/spreadsheets/#{Regexp.escape(@spreadsheet_id)}}
    stub_request(:get, base).to_return { |request| respond_to_get(request) }
    stub_request(:post, base).to_return { |request| respond_to_post(request) }
    stub_request(:put, base).to_return { |request| respond_to_put(request) }
  end

  private

  def respond_to_get(request)
    path = request.uri.path
    if path.include?("/values/")
      range = URI.decode_www_form_component(path.split("/values/").last)
      title, cell = parse_range(range)
      return not_found(title) unless @sheets.key?(title)
      json(values_payload(title, row_bounds(cell)))
    else
      json("sheets" => @sheets.keys.map { |title|
        {"properties" => {"sheetId" => @sheet_ids[title], "title" => title}}
      })
    end
  end

  def respond_to_post(request)
    path = request.uri.path
    body = JSON.parse(request.body)
    if path.end_with?("/values:batchUpdate")
      body.fetch("data").each do |entry|
        title, cell = parse_range(entry.fetch("range"))
        return not_found(title) unless @sheets.key?(title)
        write_values(title, cell, entry.fetch("values"))
      end
      json({})
    elsif path.end_with?(":batchUpdate")
      replies = body.fetch("requests").map { |batch_request| apply(batch_request) }
      json("replies" => replies)
    elsif path.include?("/values/")
      title = title_from(path)
      return not_found(title) unless @sheets.key?(title)
      @sheets[title].concat(body.fetch("values"))
      json({})
    else
      error(400, "unexpected POST #{path}")
    end
  end

  def respond_to_put(request)
    range = URI.decode_www_form_component(request.uri.path.split("/values/").last)
    title, cell = parse_range(range)
    return not_found(title) unless @sheets.key?(title)
    write_values(title, cell, JSON.parse(request.body).fetch("values"))
    json({})
  end

  def write_values(title, cell, values)
    column, row = parse_cell(cell)
    values.each_with_index do |row_values, row_offset|
      grid_row = (@sheets[title][row - 1 + row_offset] ||= [])
      row_values.each_with_index { |value, column_offset| grid_row[column - 1 + column_offset] = value }
    end
  end

  def apply(batch_request)
    if (add = batch_request["addSheet"])
      title = add.fetch("properties").fetch("title")
      raise "sheet #{title} already exists" if @sheets.key?(title)
      seed(title, [])
      {"addSheet" => {"properties" => {"sheetId" => @sheet_ids[title], "title" => title}}}
    elsif (drop = batch_request["deleteSheet"])
      title = title_for_id(drop.fetch("sheetId"))
      @sheets.delete(title)
      @sheet_ids.delete(title)
      {}
    elsif (rename = batch_request["updateSheetProperties"])
      properties = rename.fetch("properties")
      title = title_for_id(properties.fetch("sheetId"))
      @sheets[properties.fetch("title")] = @sheets.delete(title)
      @sheet_ids[properties.fetch("title")] = @sheet_ids.delete(title)
      {}
    elsif (deletion = batch_request["deleteDimension"])
      apply_delete_dimension(deletion.fetch("range"))
      {}
    else
      raise "unsupported batchUpdate request: #{batch_request.keys}"
    end
  end

  def apply_delete_dimension(range)
    title = title_for_id(range.fetch("sheetId"))
    start_index = range.fetch("startIndex")
    end_index = range.fetch("endIndex")
    if range.fetch("dimension") == "ROWS"
      @sheets[title].slice!(start_index...end_index)
    else
      @sheets[title].each { |row| row.slice!(start_index...end_index) }
    end
  end

  def values_payload(title, bounds)
    rows = @sheets[title]
    rows = rows.take(bounds) if bounds
    trimmed = rows.reverse.drop_while { |row| row.all? { |cell| blank?(cell) } }.reverse
    trimmed.empty? ? {"range" => title} : {"range" => title, "values" => trimmed}
  end

  # "1:51" limits a read to the first 51 rows; a blank cell reference reads everything.
  def row_bounds(cell)
    match = /\A(\d+):(\d+)\z/.match(cell)
    match && Integer(match[2])
  end

  def blank?(cell)
    cell.nil? || cell == ""
  end

  def title_from(path)
    range = URI.decode_www_form_component(path.split("/values/").last.sub(/:append\z/, ""))
    parse_range(range).first
  end

  def parse_range(range)
    if range.start_with?("'")
      closing = range.rindex("'")
      title = range[1...closing].gsub("''", "'")
      cell = range[(closing + 1)..].to_s.sub("!", "")
    else
      title, cell = range.split("!", 2)
    end
    [title, cell.to_s]
  end

  def parse_cell(cell)
    match = /\A([A-Z]+)(\d+)\z/.match(cell)
    raise "cannot parse cell reference #{cell.inspect}" unless match
    column = match[1].chars.reduce(0) { |total, letter| total * 26 + (letter.ord - 64) }
    [column, Integer(match[2])]
  end

  def title_for_id(sheet_id)
    @sheet_ids.key(sheet_id) or raise "no sheet with id #{sheet_id}"
  end

  def json(payload)
    {status: 200, body: JSON.generate(payload), headers: {"Content-Type" => "application/json"}}
  end

  def not_found(title)
    error(400, "Unable to parse range: #{title}")
  end

  def error(status, message)
    {status: status, body: JSON.generate("error" => {"message" => message})}
  end
end
