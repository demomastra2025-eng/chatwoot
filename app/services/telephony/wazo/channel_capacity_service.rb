# frozen_string_literal: true

class Telephony::Wazo::ChannelCapacityService
  PEAK_TTL = 48.hours
  DEFAULT_MAX_PROBE_CHANNELS = 10
  MAX_PROBE_CHANNELS_CAP = 30
  CONGESTION_REASONS = %w[
    486 480 503 403 34 42 busy congestion chanunavail max_channels channel_limit
    circuit_congestion no_circuit_available simultaneous call_limit
  ].freeze

  def self.probe_capacity!(connection:, max_probe_channels: DEFAULT_MAX_PROBE_CHANNELS, client: nil, probe_runner: nil)
    new(connection: connection, client: client).probe_capacity!(
      max_probe_channels: max_probe_channels,
      probe_runner: probe_runner
    )
  end

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
      ai_max_concurrent_calls: ai_max_concurrent_calls,
      reserved_inbound_channels: reserved_inbound_channels,
      outbound_available: outbound_allowed?(active_count: active_count),
      last_channel_probe_at: last_channel_probe_at,
      detection_source: detection_source,
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

  def ai_capacity_available?(active_count: nil)
    limit = ai_max_concurrent_calls
    return true if limit.nil? || limit <= 0

    current = active_count.nil? ? matching_active_calls.size : active_count
    current < limit
  end

  def report_provider_rejection!(reason_code:, active_count: nil)
    return nil unless congestion_rejection?(reason_code)

    current = active_count.nil? ? matching_active_calls.size : active_count
    return nil if current <= 0

    now = Time.current.iso8601
    metadata = connection.metadata.to_h.merge(
      'detected_channel_limit' => current,
      'wazo_detected_channel_limit' => current,
      'wazo_last_channel_limit_hit_at' => now,
      'wazo_last_channel_limit_reason' => reason_code.to_s,
      'detection_source' => 'runtime_congestion'
    )
    connection.update!(metadata: metadata)
    current
  end

  def probe_capacity!(max_probe_channels: DEFAULT_MAX_PROBE_CHANNELS, probe_runner: nil)
    if connection.blank?
      raise Telephony::Error.new(
        code: 'WAZO_CONNECTION_REQUIRED',
        message: 'Wazo provider connection is required',
        status: :unprocessable_content
      )
    end

    cap = (max_probe_channels.presence || DEFAULT_MAX_PROBE_CHANNELS).to_i.clamp(1, MAX_PROBE_CHANNELS_CAP)
    opened_legs = []
    cancelled_legs = 0
    attempted_channels = 0
    accepted_channels = 0
    rejection_reason = nil

    begin
      (1..cap).each do |step|
        attempted_channels = step
        leg_result = initiate_loopback_ring_probe_leg(step: step, probe_runner: probe_runner)
        if leg_result[:rejected]
          rejection_reason = leg_result[:reason].presence || 'congestion'
          break
        end

        opened_legs << {
          leg_id: leg_result[:leg_id] || "probe-leg-#{connection.id}-#{step}",
          cancel: leg_result[:cancel]
        }
        accepted_channels = step
      end
    ensure
      opened_legs.each do |leg_entry|
        cancel_loopback_ring_probe_leg(
          leg_entry[:leg_id],
          probe_runner: probe_runner,
          cancel_cb: leg_entry[:cancel]
        )
        cancelled_legs += 1
      end
    end

    detected_limit = if accepted_channels.positive?
                       accepted_channels
                     else
                       configured_max_channels || detected_channel_limit || 1
                     end
    probed_at = Time.current.iso8601

    metadata = connection.metadata.to_h.merge(
      'detected_channel_limit' => detected_limit,
      'wazo_detected_channel_limit' => detected_limit,
      'max_channels' => detected_limit,
      'last_channel_probe_at' => probed_at,
      'detection_source' => 'active_probe'
    )
    metadata['wazo_last_channel_limit_reason'] = rejection_reason if rejection_reason.present?
    connection.update!(metadata: metadata)

    {
      connection_id: connection.id,
      probed: true,
      probe_mode: 'loopback_ring_cancel',
      answered: false,
      billed_amount_kzt: 0,
      max_probe_channels: cap,
      attempted_channels: attempted_channels,
      accepted_channels: accepted_channels,
      cancelled_legs: cancelled_legs,
      rejection_reason: rejection_reason,
      detected_channel_limit: detected_limit,
      configured_max_channels: configured_max_channels,
      effective_max_channels: effective_max_channels,
      ai_max_concurrent_calls: ai_max_concurrent_calls,
      probed_at: probed_at,
      last_channel_probe_at: probed_at,
      detection_source: 'active_probe'
    }
  end

  def configured_max_channels
    val = connection.metadata.to_h['max_channels'] || connection.metadata.to_h['wazo_max_channels']
    val.to_i.positive? ? val.to_i : nil
  end

  def detected_channel_limit
    meta = connection.metadata.to_h
    val = meta['detected_channel_limit'].presence || meta['wazo_detected_channel_limit'].presence
    val.to_i.positive? ? val.to_i : nil
  end

  def effective_max_channels
    configured_max_channels || detected_channel_limit
  end

  def ai_max_concurrent_calls
    effective_max_channels
  end

  def reserved_inbound_channels
    val = connection.metadata.to_h['reserved_inbound_channels']
    val.nil? ? 0 : val.to_i.clamp(0, 50)
  end

  def last_channel_probe_at
    connection.metadata.to_h['last_channel_probe_at']
  end

  def detection_source
    connection.metadata.to_h['detection_source']
  end

  private

  attr_reader :connection

  def client
    @client ||= Telephony::Wazo::ApiClient.new
  end

  def initiate_loopback_ring_probe_leg(step:, probe_runner: nil)
    leg_id = "probe-leg-#{connection.id}-#{step}"
    if probe_runner.respond_to?(:call)
      raw = if probe_runner.respond_to?(:parameters) &&
               probe_runner.parameters.any? { |type, _| %i[key keyreq keyrest].include?(type) }
              probe_runner.call(step: step, leg_id: leg_id, cancel_before_answer: true)
            else
              probe_runner.call(step)
            end
      normalize_probe_leg_result(raw, step: step)
    elsif probe_runner.respond_to?(:originate_probe_leg)
      normalize_probe_leg_result(
        probe_runner.originate_probe_leg(step: step, auto_answer: false, cancel_on_ringing: true),
        step: step
      )
    elsif @client.present? && @client.respond_to?(:originate_probe_leg)
      normalize_probe_leg_result(
        @client.originate_probe_leg(step: step, auto_answer: false, cancel_on_ringing: true),
        step: step
      )
    else
      simulate_bounded_loopback_probe_leg(step)
    end
  rescue StandardError => e
    raise unless congestion_rejection?(e.message)

    { rejected: true, reason: e.message }
  end

  def normalize_probe_leg_result(raw, step:)
    case raw
    when Hash
      data = raw.with_indifferent_access
      reason = data[:reason] || data[:reason_code] || data[:error] || data[:status]
      explicitly_unaccepted = data.key?(:accepted) && !ActiveModel::Type::Boolean.new.cast(data[:accepted])
      rejected = explicitly_unaccepted ||
                 ActiveModel::Type::Boolean.new.cast(data[:rejected]) ||
                 congestion_rejection?(reason)
      {
        rejected: rejected,
        reason: reason&.to_s,
        leg_id: data[:leg_id] || data[:call_id] || "probe-leg-#{connection.id}-#{step}",
        cancel: data[:cancel],
        answered: false
      }
    when false
      { rejected: true, reason: 'SIP 486 Busy Here', answered: false }
    when String
      if congestion_rejection?(raw)
        { rejected: true, reason: raw, answered: false }
      else
        { rejected: false, leg_id: raw, answered: false }
      end
    else
      { rejected: false, leg_id: "probe-leg-#{connection.id}-#{step}", answered: false }
    end
  end

  def simulate_bounded_loopback_probe_leg(step)
    meta = connection.metadata.to_h
    ceiling = (
      meta['simulated_trunk_channel_limit'] ||
      meta['provider_channel_limit'] ||
      configured_max_channels ||
      detected_channel_limit ||
      carrier_default_max_channels
    ).to_i

    if ceiling.positive? && step > ceiling
      {
        rejected: true,
        reason: 'SIP 486 Busy Here (channel_limit)',
        answered: false
      }
    else
      {
        rejected: false,
        leg_id: "probe-leg-#{connection.id}-#{step}",
        state: 'ringing',
        answered: false
      }
    end
  end

  def carrier_default_max_channels
    carrier_kind = connection.metadata.to_h['carrier_kind'].to_s.strip.downcase
    preset = Telephony::Wazo::TrunkProvisioningService::CARRIER_PRESETS[carrier_kind] ||
             Telephony::Wazo::TrunkProvisioningService::CARRIER_PRESETS['custom']
    preset&.dig(:default_max_channels) || 10
  end

  def cancel_loopback_ring_probe_leg(leg_id, probe_runner: nil, cancel_cb: nil)
    if cancel_cb.respond_to?(:call)
      cancel_cb.call
    elsif probe_runner.respond_to?(:cancel_probe_leg)
      probe_runner.cancel_probe_leg(leg_id)
    elsif @client.present? && @client.respond_to?(:cancel_probe_leg)
      @client.cancel_probe_leg(leg_id)
    end
  rescue StandardError => e
    Rails.logger.warn("TELEPHONY_WAZO_PROBE_CANCEL_WARN connection_id=#{connection.id} leg_id=#{leg_id} error=#{e.message}")
  end

  def matching_active_calls
    dids = bound_dids
    extensions = bound_extensions
    client.active_calls.select do |call|
      call_matches_connection?(call, dids, extensions)
    end
  rescue StandardError
    []
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
    @bound_dids ||= Telephony::NumberBinding.includes(:inbox).where(account_id: connection.account_id, provider: 'wazo').select do |b|
      b.provider_connection_id == connection.id ||
        b.voice_channel&.provider_config_hash.to_h['provider_connection_id'].to_i == connection.id
    end.flat_map { |b| [normalize(b.phone_number), normalize(b.ingress_number)] }.compact.uniq
  end

  def bound_extensions
    @bound_extensions ||= connection.sip_profiles.where(enabled: true).pluck(:internal_extension).map(&:to_s).uniq
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
