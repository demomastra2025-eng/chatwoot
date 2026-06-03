require 'uri'

class Sipuni::RecordingUrl
  class << self
    def normalize(value)
      uri = allowed_uri(value)
      uri&.to_s
    end

    def allowed?(value)
      allowed_uri(value).present?
    end

    def allowed_uri(value)
      uri = value.is_a?(URI::Generic) ? value : URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTP) && uri.scheme == 'https'

      host = uri.host.to_s.downcase
      return unless host == 'sipuni.com' || host.end_with?('.sipuni.com')

      uri
    rescue URI::InvalidURIError
      nil
    end
  end
end
