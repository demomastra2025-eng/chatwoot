# frozen_string_literal: true

class Telephony::Wazo::ChannelCapacityService
  PEAK_TTL = 48.hours
  CONGESTION_REASONS = %w[
    486 503 busy congestion max_channels channel_limit circuit_congestion no_circuit_available
  ].freeze

  def initialize(connection:, client: nil)
    @connection = connection
    @client = client
  end

  def snapshot
    calls = matching_active_calls
    active_count = calls.size
    inbound_count = calls.count { |c| !c['is_caller'] }
    outbound_count = calls.count { |c| c['is_caller'] }
    peak_today = record_peak!(active_count)

    {
      connection_id: connection.id,
      active_channels: active_count,
      inbound_channels: inbound_count,
      outbound_channels: outbound_count,
      peak_today: peak_today,
      configured_max_channels: configured_max_channels,
      detected_channel_limit: detected_channel_limit,
      effective_max_channels: effective_max_channels,
      reserved_inbound_channels: reserved_inbound_channels,
      outbound_available: outbound_allowed?(active_count: active_count),
      checked_at: Time.current.iso8601
    }
  end

  def outbound_allowed?(active_count: nil)
    limit = effective_max_channels
    return true if limit.nil? || limit <= 0

    current = active_count.nil? ? matching_active_calls.size : active_count
    outbound_ceiling = [limit - reserved_inbound_channels, 1].max
    current < outbound_ceiling
  end

  def report_provider_rejection!(reason_code:, active_count: nil)
    return nil unless congestion_rejection?(reason_code)

    current = active_count.nil? ? matching_active_calls.size : active_count
    return nil if current <= 0

    metadata = connection.metadata.to_h.merge(
      'wazo_detected_channel_limit' => current,
      'wazo_last_channel_limit_hit_at' => Time.current.iso8601,
      'wazo_last_channel_limit_reason' => reason_code.to_s
    )
    connection.update!(metadata: metadata)
    current
  end

  private

  attr_reader :connection

  def client
    @client ||= Telephony::Wazo::ApiClient.new
  end

  def matching_active_calls
    dids = bound_dids
    extensions = bound_extensions
    client.active_calls.select do |call|
      call_matches_connection?(call, dids, extensions)
    end
  end

  def call_matches_connection?(call, dids, extensions)
    caller_num = normalize(call['caller_id_number'])
    peer_num = normalize(call['peer_caller_id_number'])
    raw_caller = call['caller_id_number'].to_s
    raw_peer = call['peer_caller_id_number'].to_s

    dids.include?(caller_num) || dids.include?(peer_num) ||
      extensions.include?(raw_caller) || extensions.include?(raw_peer)
  end

  def bound_dids
    @bound_dids ||= Telephony::NumberBinding.where(account_id: connection.account_id, provider: 'wazo')
                                            .select { |b| b.provider_connection_id == connection.id }
                                            .flat_map { |b| [normalize(b.phone_number), normalize(b.ingress_number)] }
                                            .compact.uniq
  end

  def bound_extensions
    @bound_extensions ||= connection.sip_profiles.where(enabled: true).pluck(:internal_extension).map(&:to_s).uniq
  end

  def configured_max_channels
    val = connection.metadata.to_h['max_channels'] || connection.metadata.to_h['wazo_max_channels']
    val.to_i.positive? ? val.to_i : nil
  end

  def detected_channel_limit
    val = connection.metadata.to_h['wazo_detected_channel_limit']
    val.to_i.positive? ? val.to_i : nil
  end

  def effective_max_channels
    configured_max_channels || detected_channel_limit
  end

  def reserved_inbound_channels
    val = connection.metadata.to_h['reserved_inbound_channels']
    val.nil? ? 0 : val.to_i.clamp(0, 50)
  end

  def record_peak!(active_count)
    key = peak_cache_key
    previous = Rails.cache.read(key).to_i
    peak = [previous, active_count].max
    Rails.cache.write(key, peak, expires_in: PEAK_TTL) if peak > previous || previous.zero?
    peak
  end

  def peak_cache_key
    "telephony:wazo:channels:peak:#{connection.id}:#{Time.current.in_time_zone('Asia/Almaty').to_date.iso8601}"
  end

  def congestion_rejection?(reason_code)
    normalized = reason_code.to_s.downcase
    CONGESTION_REASONS.any? { |token| normalized.include?(token) }
  end

  def normalize(value)
    return if value.blank?

    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end
end
