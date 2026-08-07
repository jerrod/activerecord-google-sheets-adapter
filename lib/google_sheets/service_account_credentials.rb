require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

module GoogleSheets
  class AuthenticationError < StandardError; end

  # Exchanges a Google service-account key for an OAuth access token.
  # The token is cached until shortly before it expires.
  class ServiceAccountCredentials
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
    SCOPE = "https://www.googleapis.com/auth/spreadsheets".freeze
    GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer".freeze
    TOKEN_LIFETIME_SECONDS = 3600
    EXPIRY_SKEW_SECONDS = 60

    def initialize(key_source)
      key = key_source.is_a?(Hash) ? key_source : read_key_file(key_source)
      @client_email = key.fetch("client_email")
      @private_key = OpenSSL::PKey::RSA.new(key.fetch("private_key"))
      @access_token = nil
      @expires_at = nil
    end

    def access_token
      fetch_token if @access_token.nil? || Time.now >= @expires_at
      @access_token
    end

    def reset
      @access_token = nil
      @expires_at = nil
    end

    private

    def read_key_file(path)
      expanded = File.expand_path(path.to_s)
      unless File.file?(expanded) && File.readable?(expanded)
        raise AuthenticationError, "service-account key file not found or not readable: #{expanded}"
      end
      JSON.parse(File.read(expanded))
    end

    def fetch_token
      issued_at = Time.now.to_i
      response = Net::HTTP.post_form(
        URI(TOKEN_URL),
        "grant_type" => GRANT_TYPE,
        "assertion" => signed_assertion(issued_at)
      )
      unless response.is_a?(Net::HTTPSuccess)
        raise AuthenticationError, "token exchange failed: HTTP #{response.code} #{oauth_error_code(response)}".rstrip
      end
      payload = JSON.parse(response.body)
      @access_token = payload.fetch("access_token")
      @expires_at = Time.at(issued_at + payload.fetch("expires_in") - EXPIRY_SKEW_SECONDS)
    end

    # Surfaces only the OAuth error code, never the raw body, so identifiers
    # echoed by the token endpoint stay out of logs and error trackers.
    def oauth_error_code(response)
      JSON.parse(response.body.to_s)["error"].to_s
    rescue JSON::ParserError
      ""
    end

    def signed_assertion(issued_at)
      header = {alg: "RS256", typ: "JWT"}
      claims = {
        iss: @client_email,
        scope: SCOPE,
        aud: TOKEN_URL,
        iat: issued_at,
        exp: issued_at + TOKEN_LIFETIME_SECONDS
      }
      signing_input = [header, claims].map { |part| base64url(JSON.generate(part)) }.join(".")
      signature = @private_key.sign(OpenSSL::Digest.new("SHA256"), signing_input)
      "#{signing_input}.#{base64url(signature)}"
    end

    def base64url(data)
      Base64.urlsafe_encode64(data, padding: false)
    end
  end
end
