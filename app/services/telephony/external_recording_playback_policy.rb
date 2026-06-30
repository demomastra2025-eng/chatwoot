# frozen_string_literal: true

class Telephony::ExternalRecordingPlaybackPolicy
  PROXIED_SIPUNI_HOSTS = %w[sipuni.com www.sipuni.com].freeze
  SIPUNI_RECORDING_PATH = '/api/crm/record'

  def self.proxy?(url)
    uri = parse(url)
    return false if uri.blank?

    uri.is_a?(URI::HTTPS) &&
      PROXIED_SIPUNI_HOSTS.include?(uri.hostname.to_s.downcase) &&
      uri.path == SIPUNI_RECORDING_PATH
  end

  def self.parse(url)
    return if url.blank?

    URI.parse(url.to_s)
  rescue URI::InvalidURIError
    nil
  end

  private_class_method :parse
end
