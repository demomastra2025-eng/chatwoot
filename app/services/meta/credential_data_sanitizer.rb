# frozen_string_literal: true

class Meta::CredentialDataSanitizer
  SENSITIVE_KEY = /
    (?:
      access[_-]?token|api[_-]?key|app[_-]?secret|client[_-]?secret|refresh[_-]?token|
      (?:oauth|authorization)[_-]?code|authorization|password|webhook[_-]?verify[_-]?token|
      verify[_-]?token|verification[_-]?pin|pin|token
    )\z
  /ix
  PROVIDER_SECRET_KEYS = %w[app_secret app_secret_key client_secret api_secret].freeze
  QUERY_SECRET = /
    ((?:access_token|api_key|app_secret|client_secret|refresh_token|oauth_code|authorization_code|
        webhook_verify_token|verify_token|code|token|verification_pin|pin)=)[^&\s"']+
  /ix
  JSON_SECRET = /
    ("(?:access_token|api_key|app_secret|client_secret|refresh_token|oauth_code|authorization_code|
        webhook_verify_token|verify_token|code|token|verification_pin|pin)"\s*:\s*")[^"]+("?)
  /ix
  LABELED_SECRET = /((?:webhook[_-]?verify[_-]?token|verify[_-]?token)\s*:\s*)[^\s,}"']+/ix
  LABELED_PIN = /((?:(?:registration|verification)\s+)?pin(?:\s+(?:is|was))?\s*[:=]?\s*)\d{4,8}\b/i
  BEARER_SECRET = /(Bearer\s+)[^\s,"']+/i

  class << self
    def sanitize(value, secrets: [])
      case value
      when Hash
        sanitize_hash(value, secrets)
      when Array
        value.map { |item| sanitize(item, secrets: secrets) }
      when String
        sanitize_string(value, secrets)
      else
        value
      end
    end

    def channel_secrets(channel)
      case channel
      when Channel::Instagram
        [channel[:access_token], GlobalConfigService.load('INSTAGRAM_APP_SECRET', '')]
      when Channel::FacebookPage
        app_id = GlobalConfigService.load('FB_APP_ID', '')
        app_secret = GlobalConfigService.load('FB_APP_SECRET', '')
        [channel.page_access_token, channel.user_access_token, app_secret, "#{app_id}|#{app_secret}"]
      when Channel::Whatsapp
        config = channel.provider_config.to_h
        [config['api_key'], config['webhook_verify_token'], config['verification_pin'],
         *PROVIDER_SECRET_KEYS.filter_map { |key| config[key] },
         GlobalConfigService.load('WHATSAPP_APP_SECRET', '')]
      else
        []
      end.compact_blank
    end

    private

    def sanitize_hash(value, secrets)
      value.each_with_object({}) do |(key, item), result|
        next if key.to_s.match?(SENSITIVE_KEY)

        result[key] = sanitize(item, secrets: secrets)
      end
    end

    def sanitize_string(value, secrets)
      safe = secrets.compact_blank.map(&:to_s).select { |secret| secret.length >= 8 }.uniq
                    .reduce(value.dup) { |text, secret| text.gsub(secret, '[FILTERED]') }
      safe.gsub(QUERY_SECRET, '\\1[FILTERED]')
          .gsub(JSON_SECRET, '\\1[FILTERED]\\2')
          .gsub(LABELED_SECRET, '\\1[FILTERED]')
          .gsub(LABELED_PIN, '\\1[FILTERED]')
          .gsub(BEARER_SECRET, '\\1[FILTERED]')
    end
  end
end
