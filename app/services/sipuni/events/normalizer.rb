require 'digest'

class Sipuni::Events::Normalizer
  TERMINAL_STATUS_MAP = {
    'ANSWER' => 'completed',
    'BUSY' => 'busy',
    'NOANSWER' => 'no_answer',
    'NO_ANSWER' => 'no_answer',
    'CANCEL' => 'cancelled',
    'CANCELLED' => 'cancelled',
    'CONGESTION' => 'failed',
    'CHANUNAVAIL' => 'failed'
  }.freeze

  def initialize(params:, inbox:)
    @params = unsafe_hash(params).deep_stringify_keys
    @inbox = inbox
    @channel = inbox.channel
  end

  def perform
    validate!

    {
      provider: 'sipuni',
      event: event_name,
      status: explicit_status,
      event_key: event_key,
      call_ref: call_ref,
      provider_call_id: call_ref,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      direction: direction,
      from_number: from_number,
      to_number: to_number,
      ingress_number: channel.phone_number,
      agent_ref: agent_binding&.agent_ref,
      chatwoot_user_id: agent_binding&.user_id,
      occurred_at: occurred_at,
      started_at: started_at,
      answered_at: answered_at,
      answered_by: answered_by,
      ended_at: ended_at,
      ended_by: ended_by,
      end_reason: end_reason,
      duration: duration_seconds,
      recording_ref: recording_url,
      recording_url: recording_url,
      metadata: metadata
    }.compact_blank
  end

  private

  attr_reader :params, :inbox, :channel

  def unsafe_hash(value)
    return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    return value.to_h if value.respond_to?(:to_h)

    {}
  end

  def validate!
    return if call_ref.present?

    raise Telephony::Error.new(
      code: 'SIPUNI_CALL_ID_REQUIRED',
      message: 'Sipuni call_id is required',
      status: :unprocessable_content
    )
  end

  def event_name
    case event_code
    when '1'
      'session_started'
    when '3'
      'answered'
    when '2'
      terminal_event_name
    when '4'
      'transfer_result'
    else
      explicit_status.presence || 'unknown'
    end
  end

  def terminal_event_name
    case explicit_status
    when 'completed'
      'session_completed'
    when 'failed'
      'provider_error'
    else
      'dial_status'
    end
  end

  def explicit_status
    return unless event_code == '2'

    TERMINAL_STATUS_MAP[raw_status]
  end

  def event_code
    params['event'].to_s.strip
  end

  def raw_status
    params['status'].to_s.strip.upcase
  end

  def call_ref
    params['call_id'].presence || params['callId'].presence || params['call_ref'].presence || params['callRef'].presence
  end

  def event_key
    [
      'sipuni',
      inbox.id,
      call_ref,
      event_code.presence || 'unknown',
      raw_status.presence || 'none',
      occurred_at.presence || Digest::SHA256.hexdigest(params.to_json)
    ].join(':')
  end

  def direction
    outbound_call? ? 'outbound' : 'inbound'
  end

  def outbound_call?
    return true if source_internal? && destination_phone.present? && !destination_is_channel_number?
    return true if source_is_channel_number? && destination_phone.present? && !destination_is_channel_number?

    false
  end

  def source_internal?
    sipuni_type(source_type) == 'internal' ||
      internal_number?(short_source_number) ||
      internal_number?(raw_source_number)
  end

  def source_is_channel_number?
    source_phone == channel.phone_number
  end

  def destination_is_channel_number?
    destination_phone == channel.phone_number
  end

  def sipuni_type(value)
    case value.to_s
    when '2', 'internal', 'inner'
      'internal'
    when '1', 'external', 'outer'
      'external'
    end
  end

  def from_number
    outbound_call? ? channel.phone_number : (source_phone || raw_source_number)
  end

  def to_number
    outbound_call? ? (destination_phone || raw_destination_number) : channel.phone_number
  end

  def source_phone
    @source_phone ||= normalize_external_phone(raw_source_number)
  end

  def destination_phone
    @destination_phone ||= normalize_external_phone(raw_destination_number)
  end

  def raw_source_number
    params['src_num'].presence || params['srcNum'].presence || params['from'].presence
  end

  def raw_destination_number
    params['dst_num'].presence || params['dstNum'].presence || params['to'].presence
  end

  def operator_internal_number
    return source_internal_number if outbound_call?
    return destination_internal_number if destination_internal?

    source_internal_number if source_internal?
  end

  def source_internal_number
    internal_login_number(short_source_number.presence || raw_source_number)
  end

  def destination_internal_number
    internal_login_number(short_destination_number.presence || raw_destination_number)
  end

  def destination_internal?
    sipuni_type(destination_type) == 'internal' ||
      internal_number?(short_destination_number) ||
      internal_number?(raw_destination_number)
  end

  def short_source_number
    params['short_src_num'].presence || params['shortSrcNum'].presence
  end

  def short_destination_number
    params['short_dst_num'].presence || params['shortDstNum'].presence
  end

  def source_type
    params['src_type'].presence || params['srcType'].presence
  end

  def destination_type
    params['dst_type'].presence || params['dstType'].presence
  end

  def normalize_external_phone(value)
    candidate = value.to_s.strip
    digits = candidate.gsub(/\D/, '')
    return if digits.length < 7

    digits = digits.delete_prefix('00')
    digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
    "+#{digits}"
  end

  def internal_number?(value)
    candidate = value.to_s.strip
    return false if candidate.blank?

    candidate.gsub(/\D/, '').length < 7
  end

  def internal_login_number(value)
    candidate = value.to_s.strip
    return if candidate.blank?
    return candidate if internal_number?(candidate)

    account_number = sipuni_account_number.to_s.strip
    without_account = candidate.delete_prefix(account_number) if account_number.present?
    return without_account if internal_number?(without_account)

    candidate
  end

  def agent_binding
    @agent_binding ||= resolve_agent_binding
  end

  def resolve_agent_binding
    extension = operator_internal_number
    return if extension.blank?
    return unless inbox.account.respond_to?(:telephony_agent_bindings)

    scope = inbox.account.telephony_agent_bindings.enabled
    sipuni_scope = scope.where(provider: 'sipuni')
    exact = sipuni_scope.find_by(agent_ref: agent_ref_candidates(extension)) ||
            scope.find_by(agent_ref: agent_ref_candidates(extension))
    return exact if exact.present?

    find_agent_binding_by_internal_number(sipuni_scope, extension) ||
      find_agent_binding_by_internal_number(scope, extension)
  end

  def agent_ref_candidates(extension)
    [
      extension,
      "sipuni:#{extension}",
      "sipuni-#{extension}",
      sipuni_login_number(extension)
    ].compact_blank.uniq
  end

  def find_agent_binding_by_internal_number(scope, extension)
    extension_key = comparable_internal_number(extension)
    return if extension_key.blank?

    scope.find_each do |binding|
      return binding if binding_internal_number_candidates(binding).any? do |candidate|
        comparable_internal_number(candidate) == extension_key
      end
    end
    nil
  end

  def binding_internal_number_candidates(binding)
    metadata = binding.metadata.to_h
    [
      binding.agent_ref,
      binding.agent_aor,
      sip_aor_user(binding.agent_aor),
      metadata['sipuni_extension'],
      metadata['sipuni_internal_number'],
      metadata['internal_number'],
      metadata['extension'],
      metadata['sipuni_login']
    ].compact_blank
  end

  def comparable_internal_number(value)
    candidate = value.to_s.strip
    candidate = sip_aor_user(candidate) if candidate.start_with?('sip:')
    candidate = internal_login_number(candidate)
    candidate.to_s.gsub(/\D/, '').presence || candidate.presence
  end

  def sip_aor_user(value)
    value.to_s.delete_prefix('sip:').split('@').first.presence
  end

  def occurred_at
    @occurred_at ||= time_iso(params['timestamp'].presence || params['occurred_at'].presence || params['occurredAt'].presence)
  end

  def started_at
    @started_at ||= time_iso(params['call_start_timestamp'].presence || params['callStartTimestamp'].presence) || (occurred_at if event_code == '1')
  end

  def answered_at
    @answered_at ||= time_iso(params['call_answer_timestamp'].presence || params['callAnswerTimestamp'].presence) || (if event_code == '3'
                                                                                                                        occurred_at
                                                                                                                      end)
  end

  def ended_at
    occurred_at if event_code == '2'
  end

  def time_iso(value)
    return if value.blank?

    raw = value.to_s.strip
    return if raw == '0'

    time = if raw.match?(/\A\d+\z/)
             integer_time(raw)
           else
             Time.zone.parse(raw)
           end
    time&.iso8601
  rescue ArgumentError
    nil
  end

  def integer_time(raw)
    timestamp = raw.to_i
    timestamp /= 1000 if raw.length >= 13
    Time.zone.at(timestamp)
  end

  def duration_seconds
    explicit_duration = params['duration'].presence || params['call_duration'].presence || params['callDuration'].presence
    return explicit_duration.to_i if explicit_duration.present?
    return unless event_code == '2'
    return 0 unless explicit_status == 'completed'

    duration_start = Time.zone.parse(answered_at.to_s) || Time.zone.parse(started_at.to_s)
    duration_end = Time.zone.parse(ended_at.to_s)
    return if duration_start.blank? || duration_end.blank?

    [duration_end.to_i - duration_start.to_i, 0].max
  rescue ArgumentError
    nil
  end

  def answered_by
    return unless event_code == '3' || explicit_status == 'completed'

    short_destination_number.presence || params['dst_user_name'].presence || params['dstUserName'].presence
  end

  def ended_by
    case explicit_status
    when 'cancelled'
      'caller'
    when 'busy', 'no_answer'
      'callee'
    when 'failed'
      'provider'
    end
  end

  def end_reason
    raw_status.downcase.presence if event_code == '2'
  end

  def recording_url
    params['call_record_link'].presence || params['callRecordLink'].presence || params['recording_url'].presence || params['recordingUrl'].presence
  end

  def metadata
    {
      provider: 'sipuni',
      account_number: sipuni_account_number,
      audio_mode: channel.provider_config_hash.with_indifferent_access[:audio_mode],
      event_code: event_code,
      status: raw_status.presence,
      operator_internal_number: operator_internal_number,
      agent_ref: agent_binding&.agent_ref,
      chatwoot_user_id: agent_binding&.user_id,
      source: {
        number: raw_source_number,
        short_number: short_source_number,
        type: source_type
      }.compact_blank,
      destination: {
        number: raw_destination_number,
        short_number: short_destination_number,
        type: destination_type
      }.compact_blank,
      is_inner_call: boolean_value(params['is_inner_call']),
      tree_name: params['tree_name'].presence || params['treeName'].presence,
      tree_number: params['tree_number'].presence || params['treeNumber'].presence,
      phone: params['phone'].presence,
      diverter: params['diverter'].presence,
      was_recorded: boolean_value(params['is_recorded'].presence || params['isRecorded'].presence),
      recording_link_present: recording_url.present?
    }.compact_blank
  end

  def boolean_value(value)
    return if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def sipuni_account_number
    channel.provider_config_hash.with_indifferent_access[:account_number]
  end

  def sipuni_login_number(extension)
    account_number = sipuni_account_number.to_s.strip
    return if account_number.blank?

    "#{account_number}#{extension}"
  end
end
