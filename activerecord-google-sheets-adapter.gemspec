require_relative "lib/google_sheets/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord-google-sheets-adapter"
  spec.version = GoogleSheets::VERSION
  spec.authors = ["Jerrod Blavos"]
  spec.email = ["jblavos@arqu.co"]

  spec.summary = "ActiveRecord adapter that uses a Google Sheet as a database"
  spec.description = "Each sheet in a spreadsheet is a table. Row 1 holds the column names. Each later row is a record."
  spec.homepage = "https://github.com/jerrod/activerecord-google-sheets-adapter"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.2", "< 9.0"
end
