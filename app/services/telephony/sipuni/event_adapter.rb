# frozen_string_literal: true

require 'digest'
require 'cgi'

module Telephony::Sipuni
end

class Telephony::Sipuni::EventAdapter
  EVENT_MAP = {
    '1' => %w[session_started ringing],
    '3' => %w[answered in_progress]
  }.freeze

  TERMINAL_STATUS_MAP = {
    'ANSWER' => %w[session_completed completed],
    'BUSY' => %w[busy busy],
    'NOANSWER' => %w[operator_no_answer no_answer],
    'CANCEL' => %w[caller_hangup cancelled],
    'CONGESTION' => %w[provider_error failed],
    'CHANUNAVAIL' => %w[provider_error failed]
  }.freeze

  INTERNAL_PARTY_TYPES = %w[2 internal employee user sip].freeze
  EXTERNAL_PARTY_TYPES = %w[1 external phone pstn].freeze
  MAX_INTERNAL_EXTENSION_LENGTH = 6

  def initialize(params)
    @raw = params.to_h.deep_stringify_keys
  end

  def payload
    return if call_id.blank?
    return if account.blank?

    {
      account_id: account.id,
      inbox_id: number_binding&.inbox_id,
      event_key: event_key,
      event: event_type,
      status: status,
      provider: 'sipuni',
      provider_call_sid: call_id,
      call_ref: call_ref,
      direction: direction,
      number_ref: number_binding&.number_ref,
      ingress_number: ingress_number,
      caller_number: caller_number,
      from_number: from_number,
      to_number: to_number,
      outbound_target_number: outbound_target_number,
      started_at: sipuni_time('call_start_timestamp') || sipuni_time('timestamp'),
      answered_at: sipuni_time('call_answer_timestamp'),
      ended_at: terminal_event? ? sipuni_time('timestamp') : nil,
      end_reason: terminal_event? ? sipuni_status.presence || status : nil,
      recording_url: raw_value('call_record_link', 'recording_link', 'recording_url'),
      operator_leg: operator_leg?,
      metadata: metadata
    }.compact
  end

  private

  attr_reader :raw

  def event_type
    terminal_event? ? terminal_mapping.first : EVENT_MAP.fetch(event_code, ['unknown', nil]).first
  end

  def status
    terminal_event? ? terminal_mapping.second : EVENT_MAP.fetch(event_code, [nil, nil]).second
  end

  def terminal_mapping
    TERMINAL_STATUS_MAP.fetch(sipuni_status, %w[session_completed completed])
  end

  def terminal_event?
    event_code.in?(%w[2 4])
  end

  def event_code
    raw_value('event', 'event_id', 'eventId').to_s
  end

  def sipuni_status
    raw_value('status', 'call_status', 'callStatus').to_s.upcase.presence
  end

  def call_id
    raw_value('call_id', 'callId', 'callid', 'call-id')
  end

  def call_ref
    existing_call_session&.external_call_ref ||
      correlated_outbound_session&.external_call_ref ||
      "sipuni:#{call_id}"
  end

  def event_key
    [
      'sipuni',
      call_id,
      event_code.presence || 'event',
      sipuni_status.presence || status.presence || 'state',
      event_key_discriminator
    ].compact.join(':')
  end

  def event_key_discriminator
    return 'recording' if terminal_event? && recording_url.present?
    return if event_code.in?(%w[1 2 3 4])

    Digest::SHA256.hexdigest(raw.except('timestamp', 'event_time', 'eventTime').to_json)
  end

  def recording_url
    raw_value('call_record_link', 'recording_link', 'recording_url')
  end

  def metadata
    {
      source: 'sipuni_http_api',
      provider: 'sipuni',
      route_action: 'operator',
      routing_mode: 'operator',
      chatwoot_account_id: account.id,
      chatwoot_inbox_id: number_binding&.inbox_id,
      direction: direction,
      call_direction: direction,
      logical_call_key: "sipuni:#{call_id}",
      call_group_key: "sipuni:#{call_id}",
      number_ref: number_binding&.number_ref,
      sipuni_call_id: call_id,
      sipuni_event: event_code,
      sipuni_status: sipuni_status,
      sipuni_leg_kind: sipuni_leg_kind,
      sipuni_operator_leg: operator_leg?,
      operator_internal_extension: internal_extension_for_candidates,
      outbound_target_number: outbound_target_number,
      raw_sipuni_payload: raw
    }.merge(operator_candidate_metadata).compact
  end

  def operator_candidate_metadata
    candidates = candidate_profiles.map do |profile|
      {
        source: 'sip_profile',
        sip_profile_id: profile.id,
        user_id: profile.user_id,
        user_name: profile.user&.name,
        agent_ref: profile.agent_ref,
        agent_aor: profile.agent_aor,
        internal_extension: profile.internal_extension
      }.compact
    end

    return {} if candidates.blank?

    {
      operator_pool: true,
      operator_pool_size: candidates.size,
      operator_candidates: candidates,
      operator_candidate_sip_profile_ids: candidates.filter_map { |candidate| candidate[:sip_profile_id] },
      operator_candidate_user_ids: candidates.filter_map { |candidate| candidate[:user_id] },
      operator_candidate_agent_refs: candidates.filter_map { |candidate| candidate[:agent_ref] },
      operator_candidate_agent_aors: candidates.filter_map { |candidate| candidate[:agent_aor] },
      operator_candidate_sources: candidates.filter_map { |candidate| candidate[:source] }
    }
  end

  def candidate_profiles
    return Telephony::SipProfile.none if number_binding.blank? || number_binding.inbox.blank?
    return Telephony::SipProfile.none if inbound? && !operator_leg?

    scope = number_binding.inbox.telephony_sip_profiles.enabled.includes(:user).where.not(status: %w[disabled deleting failed])
    matching_extension = internal_extension_for_candidates
    scope = scope.where(internal_extension: matching_extension) if matching_extension.present?
    scope.order(:id).to_a
  end

  def internal_extension_for_candidates
    directional_internal_extension_candidates.find do |value|
      internal_extension?(value) || internal_extension_candidate?(value)
    end
  end

  def operator_leg?
    return false unless inbound?

    internal_extension_for_candidates.present? && (
      truthy_raw_value?('is_inner_call', 'isInnerCall') ||
      internal_type?(raw_value('dst_type', 'dstType')) ||
      sip_username_from_channel.present?
    )
  end

  def sipuni_leg_kind
    return 'outbound' if outbound?

    operator_leg? ? 'operator' : 'external'
  end

  def account
    @account ||= begin
      account_id = raw_value('account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId')
      Account.find_by(id: account_id) ||
        existing_call_session&.account ||
        number_binding&.account ||
        correlated_outbound_session&.account
    end
  end

  def number_binding
    @number_binding ||= begin
      @resolving_number_binding = true
      outbound_binding = existing_call_session&.number_binding || correlated_outbound_session&.number_binding
      if outbound_binding.present?
        outbound_binding
      else
        scoped = Telephony::NumberBinding.where(provider: 'sipuni')
        account_id = raw_value('account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId')
        scoped = scoped.where(account_id: account_id) if account_id.present?

        find_binding(scoped) || unique_binding(scoped)
      end
    ensure
      @resolving_number_binding = false
    end
  end

  def find_binding(scope)
    refs = [raw_value('number_ref', 'numberRef')].compact_blank
    binding = scope.find_by(number_ref: refs.first) if refs.first.present?
    return binding if binding.present?

    binding = binding_from_sip_username(scope)
    return binding if binding.present?

    phone_candidates.each do |candidate|
      binding = scope.find_by(phone_number: candidate) ||
                scope.find_by(display_phone_number: candidate) ||
                scope.find_by(ingress_number: candidate) ||
                scope.find_by(provider_account_number: candidate)
      return binding if binding.present?
    end

    binding_from_internal_extension(scope)
  end

  def binding_from_sip_username(scope)
    username = sip_username_from_channel
    return if username.blank?

    bindings_for_profiles(scope, Telephony::SipProfile.where(sip_username: username))
  end

  def binding_from_internal_extension(scope)
    extension = internal_extension_for_binding
    return if extension.blank?

    bindings_for_profiles(scope, Telephony::SipProfile.where(internal_extension: extension))
  end

  def bindings_for_profiles(scope, profiles)
    inbox_ids = scope.select(:inbox_id)
    bindings = profiles
               .where(inbox_id: inbox_ids)
               .includes(inbox: :telephony_number_binding)
               .filter_map { |profile| profile.inbox&.telephony_number_binding }
               .select { |binding| binding.provider == 'sipuni' }
               .uniq(&:id)

    bindings.one? ? bindings.first : nil
  end

  def sip_username_from_channel
    channel = decoded_channel
    return if channel.blank?

    channel.match(%r{\ASIP/(\d{7,})-})&.[](1)
  end

  def decoded_channel
    CGI.unescape(raw_value('channel').to_s)
  rescue ArgumentError
    raw_value('channel').to_s
  end

  def internal_extension_for_binding
    directional_internal_extension_candidates.find { |value| internal_extension_candidate?(value) }
  end

  def directional_internal_extension_candidates
    values = outbound_hint? ? outbound_internal_extension_values : inbound_internal_extension_values
    extension_candidates(*values)
  end

  def outbound_internal_extension_values
    [
      raw_value('short_src_num', 'shortSrcNum'),
      raw_value('src_num', 'srcNum'),
      raw_value('transfer_from', 'transferFrom')
    ]
  end

  def inbound_internal_extension_values
    [
      raw_value('short_dst_num', 'shortDstNum'),
      raw_value('dst_num', 'dstNum'),
      raw_value('last_called', 'lastCalled'),
      raw_value('transfer_from', 'transferFrom')
    ]
  end

  def extension_candidates(*values)
    values.compact_blank.flat_map do |value|
      raw_candidate = value.to_s.strip
      candidates = [raw_candidate]
      if sipuni_user_id.present? && raw_candidate.start_with?(sipuni_user_id) && raw_candidate.length > sipuni_user_id.length
        candidates << raw_candidate.delete_prefix(sipuni_user_id)
      end
      candidates
    end.compact_blank.uniq
  end

  def internal_extension_candidate?(value)
    candidate = value.to_s.strip
    candidate.match?(/\A\d{1,#{MAX_INTERNAL_EXTENSION_LENGTH}}\z/o)
  end

  def sipuni_user_id
    @sipuni_user_id ||= raw_value('user_id', 'userId', 'user').to_s.strip.presence
  end

  def existing_call_session
    @existing_call_session ||=
      if call_id.present?
        sessions = Telephony::CallSession
                   .where(provider: 'sipuni')
                   .where('provider_call_sid = :call_id OR external_call_ref = :call_ref',
                          call_id: call_id,
                          call_ref: "sipuni:#{call_id}")
                   .limit(2)
                   .to_a
        sessions.one? ? sessions.first : nil
      end
  end

  def scoped_binding_from_channel
    @scoped_binding_from_channel ||= binding_from_sip_username(Telephony::NumberBinding.where(provider: 'sipuni'))
  end

  def outbound_hint?
    return true if internal_type?(raw_value('src_type', 'srcType')) && external_type?(raw_value('dst_type', 'dstType'))
    return false if external_type?(raw_value('src_type', 'srcType')) && internal_type?(raw_value('dst_type', 'dstType'))

    source_extension = extension_candidates(*outbound_internal_extension_values).find { |value| internal_extension_candidate?(value) }
    destination_extension = extension_candidates(*inbound_internal_extension_values).find { |value| internal_extension_candidate?(value) }
    source_extension.present? && destination_extension.blank?
  end

  def channel_phone_candidates
    decoded_channel.scan(/\+?\d{6,}/)
  end

  def unique_record(records)
    records = records.compact.uniq(&:id)
    records.one? ? records.first : nil
  end

  def matching_outbound_sessions(scope, target)
    scope.to_a.select { |session| normalize_phone(session.to_number) == target }
  end

  def unique_outbound_session(scope, target)
    unique_record(matching_outbound_sessions(scope, target))
  end

  def apply_outbound_session_scope(scope)
    if scoped_binding_from_channel.present?
      scope.where(number_binding_id: scoped_binding_from_channel.id)
    elsif raw_value('account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId').present?
      scope.where(account_id: raw_value('account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId'))
    else
      scope
    end
  end

  def outbound_session_scope_scoped?
    scoped_binding_from_channel.present? ||
      raw_value('account_id', 'accountId', 'chatwoot_account_id', 'chatwootAccountId').present?
  end

  def outbound_session_scope
    scope = Telephony::CallSession
            .where(provider: 'sipuni', direction: 'outbound')
            .where.not(status: Telephony::CallSession::TERMINAL_STATUS_VALUES)
            .where(created_at: 30.minutes.ago..Time.current)
            .order(created_at: :desc, id: :desc)

    apply_outbound_session_scope(scope)
  end

  def unscoped_unique_outbound_session(target)
    scope = Telephony::CallSession
            .where(provider: 'sipuni', direction: 'outbound')
            .where.not(status: Telephony::CallSession::TERMINAL_STATUS_VALUES)
            .where(created_at: 30.minutes.ago..Time.current)
            .order(created_at: :desc, id: :desc)
            .limit(20)

    unique_outbound_session(scope, target)
  end

  def provider_bound_outbound_session(target)
    scoped_session = unique_outbound_session(outbound_session_scope.limit(20), target)
    return scoped_session if scoped_session.present? || outbound_session_scope_scoped?

    unscoped_unique_outbound_session(target)
  end

  def phone_lookup_values
    [
      raw_value('dst_num', 'dstNum'),
      raw_value('src_num', 'srcNum'),
      raw_value('short_dst_num', 'shortDstNum'),
      raw_value('short_src_num', 'shortSrcNum'),
      raw_value('pbxdstnum', 'pbxDstNum', 'pbx_dst_num'),
      raw_value('last_called', 'lastCalled'),
      ENV.fetch('SIPUNI_EXTERNAL_NUMBER', nil),
      ENV.fetch('SIPUNI_INTERNAL_NUMBER', nil),
      *channel_phone_candidates
    ]
  end

  def phone_candidates
    @phone_candidates ||= phone_lookup_values.compact_blank.flat_map { |value| phone_variants(value) }.compact_blank.uniq
  end

  def correlated_outbound_session
    @correlated_outbound_session ||=
      if outbound?
        target = normalize_phone(outbound_target_number)
        provider_bound_outbound_session(target) if target.present?
      end
  end

  def phone_variants(value)
    raw_value = value.to_s.strip
    normalized = normalize_phone(raw_value)
    [
      raw_value,
      normalized,
      normalized&.delete_prefix('+'),
      raw_value.delete_prefix('+')
    ].compact_blank.uniq
  end

  def outbound?
    return true if outbound_hint?

    internal_extension?(raw_value('short_src_num', 'shortSrcNum')) || internal_extension?(raw_value('src_num', 'srcNum'))
  end

  def inbound?
    !outbound?
  end

  def external_source_number
    normalize_phone(raw_value('src_num', 'srcNum')) || raw_value('src_num', 'srcNum')
  end

  def normalize_phone(value)
    Contacts::PhoneNumberNormalizer.normalize(value) ||
      Contacts::PhoneNumberNormalizer.normalize(value, default_country: 'KZ')
  end

  def sipuni_time(*keys)
    value = raw_value(*keys)
    return if value.blank?

    if value.to_s.match?(/\A\d+\z/)
      number = value.to_i
      number /= 1000 if number > 99_999_999_999
      return Time.zone.at(number).iso8601
    end

    Time.zone.parse(value.to_s)&.iso8601
  rescue ArgumentError, TypeError
    nil
  end

  def unique_binding(scope)
    bindings = scope.limit(2).to_a
    bindings.one? ? bindings.first : nil
  end

  def direction
    outbound? ? 'outbound' : 'inbound'
  end

  def internal_extension?(value)
    candidate = value.to_s.strip
    return false if candidate.blank?

    return true if candidate == ENV.fetch('SIPUNI_INTERNAL_NUMBER', nil).to_s
    return false if @resolving_number_binding

    return true if number_binding&.inbox&.telephony_sip_profiles&.where(internal_extension: candidate)&.exists?

    false
  end

  def internal_type?(value)
    INTERNAL_PARTY_TYPES.include?(value.to_s.strip.downcase)
  end

  def external_type?(value)
    EXTERNAL_PARTY_TYPES.include?(value.to_s.strip.downcase)
  end

  def ingress_number
    return number_binding.phone_number if number_binding.present?

    normalize_phone(raw_value('dst_num', 'dstNum')) || raw_value('dst_num', 'dstNum') if inbound?
  end

  def caller_number
    inbound? ? external_source_number : from_number
  end

  def from_number
    outbound? ? (number_binding&.phone_number || ENV.fetch('SIPUNI_EXTERNAL_NUMBER', nil)) : external_source_number
  end

  def to_number
    return outbound_target_number if outbound?

    number_binding&.phone_number ||
      normalize_phone(raw_value('dst_num', 'dstNum')) ||
      raw_value('dst_num', 'dstNum')
  end

  def outbound_target_number
    return unless outbound?

    normalize_phone(raw_value('dst_num', 'dstNum')) || raw_value('dst_num', 'dstNum')
  end

  def raw_value(*keys)
    keys.lazy.map { |key| raw[key.to_s] || raw[key.to_sym] }.find(&:present?)
  end

  def truthy_raw_value?(*keys)
    ActiveModel::Type::Boolean.new.cast(raw_value(*keys))
  end
end
