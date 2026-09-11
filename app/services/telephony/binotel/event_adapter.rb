# frozen_string_literal: true

require 'json'

module Telephony::Binotel
end

class Telephony::Binotel::EventAdapter
  STATUS_MAP = {
    'ANSWER' => %w[session_completed completed],
    'TRANSFER' => %w[session_completed completed],
    'BUSY' => %w[busy busy],
    'NOANSWER' => %w[operator_no_answer no_answer],
    'CANCEL' => %w[caller_hangup cancelled],
    'CONGESTION' => %w[provider_error failed],
    'CHANUNAVAIL' => %w[provider_error failed],
    'VM' => %w[operator_no_answer no_answer],
    'VM-SUCCESS' => %w[session_completed completed]
  }.freeze
  SUCCESSFUL_STATUSES = %w[ANSWER TRANSFER VM-SUCCESS].freeze
  MISSED_INBOUND_STATUSES = %w[NOANSWER CHANUNAVAIL VM].freeze
  CALL_TYPE_DIRECTION = { '0' => 'inbound', '1' => 'outbound' }.freeze

  def initialize(params)
    @raw = params.to_h.deep_stringify_keys
  end

  def payload
    return unless raw_value('requestType', 'request_type') == 'apiCallCompleted'
    return if general_call_id.blank?
    return if direction.blank?
    return unless STATUS_MAP.key?(disposition)

    event_payload.merge(timing_payload).compact
  end

  private

  attr_reader :raw

  def event_payload
    {
      account_id: raw_value('chatwoot_account_id', 'account_id'),
      inbox_id: raw_value('chatwoot_inbox_id', 'inbox_id'),
      number_ref: raw_value('number_ref'),
      event_key: event_key,
      event: normalized_event_and_status.first,
      status: normalized_event_and_status.second,
      provider: 'binotel',
      provider_call_sid: general_call_id,
      call_ref: correlated_native_webphone_session&.external_call_ref || "binotel:#{general_call_id}",
      direction: direction,
      from_number: from_number,
      to_number: to_number,
      end_reason: disposition,
      metadata: metadata
    }
  end

  def timing_payload
    {
      started_at: parsed_start_time&.iso8601,
      answered_at: answered_at&.iso8601,
      ended_at: ended_at&.iso8601,
      duration: bill_seconds
    }
  end

  def call_details
    @call_details ||= unwrap_call_details(normalize_call_details(raw_value('callDetails', 'call_details')))
  end

  def normalize_call_details(value)
    value = JSON.parse(value) if value.is_a?(String)
    value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
  rescue JSON::ParserError, TypeError
    {}
  end

  def unwrap_call_details(value)
    return value if value['generalCallID'].present? || value['general_call_id'].present?
    return value unless value.values.one? && value.values.first.respond_to?(:to_h)

    value.values.first.to_h.deep_stringify_keys
  end

  def detail_value(*keys)
    keys.each do |key|
      value = call_details[key.to_s]
      return value if value.present?
    end
    nil
  end

  def raw_value(*keys)
    keys.each do |key|
      value = raw[key.to_s]
      return value if value.present?
    end
    nil
  end

  def general_call_id
    detail_value('generalCallID', 'general_call_id', 'callID', 'call_id')&.to_s
  end

  def disposition
    detail_value('disposition').to_s.upcase.presence || 'UNKNOWN'
  end

  def direction
    CALL_TYPE_DIRECTION[detail_value('callType', 'call_type').to_s]
  end

  def normalized_event_and_status
    mapped = STATUS_MAP.fetch(disposition, %w[provider_error failed])
    return %w[missed missed] if direction == 'inbound' && MISSED_INBOUND_STATUSES.include?(disposition)

    mapped
  end

  def event_key
    "binotel:#{general_call_id}:completed:#{disposition}"
  end

  def from_number
    direction == 'inbound' ? normalized_external_number : normalized_company_number
  end

  def to_number
    direction == 'inbound' ? normalized_company_number : normalized_external_number
  end

  def normalized_external_number
    normalize_phone(detail_value('externalNumber', 'external_number'))
  end

  def normalized_company_number
    number = raw_value('ingress_number') || detail_value('pbxNumber', 'pbx_number') || pbx_number_data['number']
    normalize_phone(number) || number
  end

  def pbx_number_data
    value = detail_value('pbxNumberData', 'pbx_number_data')
    value.respond_to?(:to_h) ? value.to_h.deep_stringify_keys : {}
  end

  def parsed_start_time
    parse_time(detail_value('startTime', 'start_time'))
  end

  def received_at
    parse_time(raw_value('received_at')) || Time.current
  end

  def answered_at
    return unless SUCCESSFUL_STATUSES.include?(disposition)

    parsed_start_time && (parsed_start_time + wait_seconds)
  end

  def ended_at
    return received_at if parsed_start_time.blank?

    parsed_start_time + wait_seconds + bill_seconds
  end

  def wait_seconds
    [detail_value('waitsec', 'wait_sec').to_i, 0].max
  end

  def bill_seconds
    [detail_value('billsec', 'bill_sec').to_i, 0].max
  end

  def parse_time(value)
    return if value.blank?

    return Time.zone.at(value.to_i) if value.to_s.match?(/\A\d+\z/)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_phone(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end

  def correlated_native_webphone_session
    return @correlated_native_webphone_session if defined?(@correlated_native_webphone_session)

    @correlated_native_webphone_session = Telephony::Binotel::NativeWebphoneCorrelator.new(
      account_id: raw_value('chatwoot_account_id', 'account_id'),
      inbox_id: raw_value('chatwoot_inbox_id', 'inbox_id'),
      started_at: parsed_start_time,
      ended_at: ended_at,
      received_at: received_at,
      from_number: from_number,
      to_number: to_number,
      direction: direction
    ).call_session
  end

  def metadata
    {
      source: 'binotel_api_call_completed',
      provider: 'binotel',
      route_action: 'operator',
      routing_mode: 'operator',
      logical_call_key: "binotel:#{general_call_id}",
      logical_call_root_ref: "binotel:#{general_call_id}",
      binotel_general_call_id: general_call_id,
      binotel_disposition: disposition,
      binotel_history_data: detail_value('historyData', 'history_data'),
      binotel_native_webphone_correlation: correlated_native_webphone_session.present?,
      chatwoot_account_id: raw_value('chatwoot_account_id', 'account_id'),
      chatwoot_inbox_id: raw_value('chatwoot_inbox_id', 'inbox_id')
    }.compact
  end
end
