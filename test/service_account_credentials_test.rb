require_relative "test_helper"

require "google_sheets/service_account_credentials"
require "tempfile"

class ServiceAccountCredentialsTest < Minitest::Test
  def setup
    @key = OpenSSL::PKey::RSA.new(2048)
    @credentials_hash = {
      "client_email" => "robot@example.iam.gserviceaccount.com",
      "private_key" => @key.to_pem
    }
  end

  def stub_token(expires_in: 3600)
    stub_request(:post, GoogleSheets::ServiceAccountCredentials::TOKEN_URL)
      .to_return(
        status: 200,
        body: JSON.generate("access_token" => "issued-token", "expires_in" => expires_in),
        headers: {"Content-Type" => "application/json"}
      )
  end

  def test_exchanges_a_signed_jwt_for_a_token
    stub_token
    credentials = GoogleSheets::ServiceAccountCredentials.new(@credentials_hash)
    assert_equal "issued-token", credentials.access_token

    assert_requested(:post, GoogleSheets::ServiceAccountCredentials::TOKEN_URL) do |request|
      params = URI.decode_www_form(request.body).to_h
      assert_equal GoogleSheets::ServiceAccountCredentials::GRANT_TYPE, params["grant_type"]
      header, claims, signature = params["assertion"].split(".")
      decoded_claims = JSON.parse(Base64.urlsafe_decode64(claims))
      assert_equal "robot@example.iam.gserviceaccount.com", decoded_claims["iss"]
      assert_equal GoogleSheets::ServiceAccountCredentials::SCOPE, decoded_claims["scope"]
      assert @key.verify(
        OpenSSL::Digest.new("SHA256"),
        Base64.urlsafe_decode64(signature),
        "#{header}.#{claims}"
      )
      true
    end
  end

  def test_caches_the_token_until_expiry
    stub_token
    credentials = GoogleSheets::ServiceAccountCredentials.new(@credentials_hash)
    2.times { credentials.access_token }
    assert_requested :post, GoogleSheets::ServiceAccountCredentials::TOKEN_URL, times: 1
  end

  def test_refreshes_an_expired_token_and_resets_on_demand
    stub_token(expires_in: GoogleSheets::ServiceAccountCredentials::EXPIRY_SKEW_SECONDS)
    credentials = GoogleSheets::ServiceAccountCredentials.new(@credentials_hash)
    2.times { credentials.access_token }
    assert_requested :post, GoogleSheets::ServiceAccountCredentials::TOKEN_URL, times: 2

    credentials.reset
    credentials.access_token
    assert_requested :post, GoogleSheets::ServiceAccountCredentials::TOKEN_URL, times: 3
  end

  def test_reads_the_key_from_a_file
    stub_token
    Tempfile.create(["service-account", ".json"]) do |file|
      file.write(JSON.generate(@credentials_hash))
      file.flush
      credentials = GoogleSheets::ServiceAccountCredentials.new(file.path)
      assert_equal "issued-token", credentials.access_token
    end
  end

  def test_raises_on_a_failed_exchange
    stub_request(:post, GoogleSheets::ServiceAccountCredentials::TOKEN_URL)
      .to_return(status: 401, body: "bad grant")
    credentials = GoogleSheets::ServiceAccountCredentials.new(@credentials_hash)
    error = assert_raises(GoogleSheets::AuthenticationError) { credentials.access_token }
    assert_match(/401/, error.message)
  end
end
