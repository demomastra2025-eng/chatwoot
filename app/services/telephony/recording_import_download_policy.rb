require 'ipaddr'

class Telephony::RecordingImportDownloadPolicy
  DEFAULT_ALLOWED_HOSTS = %w[cloud.vconsult.kz].freeze
  BLOCKED_LITERAL_IP_RANGES = %w[
    0.0.0.0/8
    10.0.0.0/8
    127.0.0.0/8
    169.254.0.0/16
    172.16.0.0/12
    192.168.0.0/16
    ::1/128
    fc00::/7
    fe80::/10
  ].map { |range| IPAddr.new(range) }.freeze

  def self.allowed?(uri)
    return false unless uri.is_a?(URI::HTTPS)

    host = uri.host.to_s.downcase
    return false if blocked_literal_host?(host)

    allowed_hosts.any? { |allowed_host| host_matches?(host, allowed_host) }
  end

  def self.allowed_hosts
    ENV.fetch('TELEPHONY_RECORDING_IMPORT_ALLOWED_HOSTS', DEFAULT_ALLOWED_HOSTS.join(','))
       .split(',')
       .map { |host| host.strip.downcase }
       .reject(&:blank?)
       .uniq
  end

  def self.blocked_literal_host?(host)
    return true if host.blank? || host == 'localhost' || host.end_with?('.localhost')

    ip = IPAddr.new(host)
    BLOCKED_LITERAL_IP_RANGES.any? { |range| range.include?(ip) }
  rescue IPAddr::InvalidAddressError
    false
  end

  def self.host_matches?(host, allowed_host)
    return false if allowed_host.blank?
    return host == allowed_host if allowed_host.exclude?('*') && !allowed_host.start_with?('.')

    suffix = allowed_host.delete_prefix('*.').delete_prefix('.')
    host == suffix || host.end_with?(".#{suffix}")
  end

  private_class_method :blocked_literal_host?, :host_matches?
end
