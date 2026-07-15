class Telephony::OperatorCallClaimService
  PROVIDER_OWNED_SIP_PROVIDERS = %w[asterisk_analog sipuni binotel].freeze

  def initialize(account:, user:, call_ref:)
    @account = account
    @user = user
    @call_ref = call_ref.to_s.strip
  end

  def perform
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

    operator_availability.with_lock do
      call_session.with_lock do
        raise_terminal_call! if call_session.terminal?
        raise_not_candidate! unless candidate_user?

        if claimed_by_other?
          raise Telephony::Error.new(
            code: 'CALL_ALREADY_CLAIMED',
            message: 'Call was already claimed by another operator',
            status: :conflict,
            details: claim_details
          )
        end

        claim_call!
      end
    end

    broadcast_claimed_call!
    claim_payload
  end

  private

  attr_reader :account, :user, :call_ref

  def call_session
    @call_session ||= account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def operator_availability
    @operator_availability ||= Telephony::OperatorBusyService.new(
      account: account,
      user: user,
      excluding_telephony_call: call_session
    )
  end

  def agent_binding
    @agent_binding ||= account.telephony_agent_bindings.find_by(user_id: user.id)
  end

  def sip_profile
    @sip_profile ||= begin
      scope = sip_profile_scope
      scope = scope.where(id: operator_candidate_sip_profile_ids) if operator_candidate_sip_profile_ids.present?
      scope.find_by(user_id: user.id)
    end
  end

  def sip_profile_scope
    current_inbox = call_session.inbox
    return current_inbox.telephony_sip_profiles if current_inbox.respond_to?(:telephony_sip_profiles)

    account.telephony_sip_profiles.where(inbox_id: call_session.inbox_id)
  end

  def operator_identity
    @operator_identity ||= sip_profile || agent_binding
  end

  def operator_agent_binding
    operator_identity if operator_identity.is_a?(Telephony::AgentBinding)
  end

  def candidate_user?
    return false unless operator_route?
    return false unless sipuni_operator_leg_claimable?
    return false unless operator_identity_enabled?
    return false unless operator_identity_registered_for_routing?
    return false unless inbox_member?
    return false unless candidate_binding_id?
    return false unless candidate_sip_profile_id?
    return false unless candidate_agent_ref?

    candidate_user_id?
  end

  def operator_identity_enabled?
    return false if operator_identity.blank?
    return operator_identity.enabled? if operator_identity.respond_to?(:enabled?)

    false
  end

  def operator_identity_registered_for_routing?
    return agent_binding.registered_for_routing? if operator_identity.is_a?(Telephony::AgentBinding)

    sip_profile&.registered_for_routing?
  end

  def candidate_binding_id?
    candidate_binding_ids = operator_candidate_binding_ids
    candidate_binding_ids.blank? || candidate_binding_ids.include?(operator_agent_binding&.id)
  end

  def candidate_sip_profile_id?
    candidate_sip_profile_ids = operator_candidate_sip_profile_ids
    candidate_sip_profile_ids.blank? || candidate_sip_profile_ids.include?(sip_profile&.id)
  end

  def candidate_agent_ref?
    candidate_agent_refs = operator_candidate_agent_refs
    candidate_agent_refs.blank? || candidate_agent_refs.include?(operator_agent_ref)
  end

  def candidate_user_id?
    candidate_user_ids = operator_candidate_user_ids
    candidate_user_ids.blank? || candidate_user_ids.include?(user.id)
  end

  def operator_route?
    route_metadata['route_action'].to_s == 'operator' ||
      route_metadata['routing_mode'].to_s == 'operator' ||
      route_metadata['mode'].to_s == 'operator' ||
      route_metadata['operator_pool'].present? ||
      route_metadata['operator_candidates'].present? ||
      route_metadata['operator_candidate_user_ids'].present? ||
      route_metadata['operator_candidate_agent_refs'].present? ||
      route_metadata['operator_candidate_sip_profile_ids'].present? ||
      virtual_pbx_target_route?
  end

  def inbox_member?
    return true if call_session.inbox.blank?
    return true unless call_session.inbox.inbox_members.exists?

    call_session.inbox.inbox_members.exists?(user_id: user.id)
  end

  def operator_candidate_binding_ids
    Array.wrap(route_metadata['operator_candidate_binding_ids']).filter_map { |value| value.presence&.to_i }
  end

  def operator_candidate_sip_profile_ids
    ids = Array.wrap(route_metadata['operator_candidate_sip_profile_ids']).filter_map { |value| value.presence&.to_i }
    ids << route_metadata['telephony_sip_profile_id'].presence&.to_i if ids.blank? && virtual_pbx_target_route?
    ids << route_metadata['target_sip_profile_id'].presence&.to_i if ids.blank? && virtual_pbx_target_route?
    ids.compact.uniq
  end

  def operator_candidate_agent_refs
    Array.wrap(route_metadata['operator_candidate_agent_refs']).filter_map { |value| value.presence&.to_s }
  end

  def operator_candidate_user_ids
    ids = Array.wrap(route_metadata['operator_candidate_user_ids']).filter_map { |value| value.presence&.to_i }
    ids << route_metadata['onelink_user_id'].presence&.to_i if ids.blank? && virtual_pbx_target_route?
    ids << route_metadata['target_user_id'].presence&.to_i if ids.blank? && virtual_pbx_target_route?
    ids.compact.uniq
  end

  def virtual_pbx_target_route?
    route_metadata['source'].to_s == 'sipuni_internal_asterisk_gateway' ||
      route_metadata['routeMode'].to_s == 'internal_asterisk_gateway' ||
      route_metadata['route_mode'].to_s == 'internal_asterisk_gateway' ||
      route_metadata['target_extension'].present? ||
      route_metadata['target_operator_agent_aor'].present? ||
      route_metadata['operator_agent_aor'].present? ||
      route_metadata['onelink_user_id'].present?
  end

  def route_metadata
    @route_metadata ||= begin
      metadata = call_session.metadata || {}
      nested = metadata['metadata'] || metadata[:metadata] || {}
      nested.is_a?(Hash) ? nested.deep_stringify_keys : {}
    end
  end

  def claimed_by_other?
    return call_session.agent_binding_id != operator_agent_binding&.id if call_session.agent_binding_id.present?

    operator_claim_user_id.present? && operator_claim_user_id != user.id
  end

  def raise_terminal_call!
    raise Telephony::Error.new(
      code: 'CALL_NOT_CLAIMABLE',
      message: 'Call is already finished',
      status: :conflict,
      details: { status: call_session.status }
    )
  end

  def raise_not_candidate!
    raise Telephony::Error.new(
      code: 'OPERATOR_NOT_CANDIDATE',
      message: 'Current user is not an available operator candidate for this call',
      status: :forbidden,
      details: not_candidate_details
    )
  end

  def not_candidate_details
    base = {
      reason: not_candidate_reason,
      user_id: user.id,
      agent_binding_id: operator_agent_binding&.id,
      sip_profile_id: sip_profile&.id,
      agent_ref: operator_agent_ref,
      registered_for_routing: operator_identity_registered_for_routing?,
      inbox_id: call_session.inbox_id
    }

    base.merge(registration_details).compact
  end

  def not_candidate_reason
    return 'call_not_operator_route' unless operator_route?
    return 'sipuni_operator_leg_not_ready' unless sipuni_operator_leg_claimable?
    return 'operator_identity_missing' if operator_identity.blank?
    return 'operator_identity_disabled' unless operator_identity_enabled?
    return 'operator_not_registered' unless operator_identity_registered_for_routing?
    return 'operator_not_in_inbox' unless inbox_member?
    return 'operator_binding_not_in_candidate_pool' unless candidate_binding_id?
    return 'operator_sip_profile_not_in_candidate_pool' unless candidate_sip_profile_id?
    return 'operator_agent_ref_not_in_candidate_pool' unless candidate_agent_ref?
    return 'operator_user_not_in_candidate_pool' unless candidate_user_id?

    'operator_not_candidate'
  end

  def sipuni_operator_leg_claimable?
    return true unless call_session.provider == 'sipuni' && call_session.direction == 'inbound'
    return true if route_metadata['sipuni_operator_leg'] == true
    return true if route_metadata['sipuni_operator_leg'].to_s == 'true'
    return true if route_metadata['sipuni_leg_kind'].to_s == 'operator'
    return false if route_metadata['sipuni_operator_leg'] == false
    return false if route_metadata['sipuni_operator_leg'].to_s == 'false'
    return false if route_metadata['sipuni_leg_kind'].to_s == 'external'

    true
  end

  def registration_details
    telephony = operator_identity&.to_telephony_h || {}
    {
      registration_state: telephony[:registration_state] || (sip_profile.present? ? sip_profile.availability_mode : nil),
      last_presence_source: telephony[:last_presence_source],
      last_presence_event_at: telephony[:last_presence_event_at],
      last_synced_at: telephony[:last_synced_at]&.iso8601
    }
  end

  def claim_call!
    claimed_at = Time.current
    attrs = {
      answered_by: call_session.answered_by || "user:#{user.id}",
      status: claim_status,
      last_event_at: [call_session.last_event_at, claimed_at].compact.max,
      metadata: (call_session.metadata || {}).deep_merge(
        'operator_claim' => {
          'agent_binding_id' => operator_agent_binding&.id,
          'sip_profile_id' => sip_profile&.id,
          'agent_ref' => operator_agent_ref,
          'agent_aor' => operator_agent_aor,
          'user_id' => user.id,
          'user_name' => user.name,
          'claimed_at' => claimed_at.iso8601
        }.compact
      )
    }
    attrs[:agent_binding] = operator_agent_binding if operator_agent_binding.present?
    call_session.update!(attrs)
  end

  def claim_status
    return call_session.status if call_session.status == 'in_progress' || call_session.status == 'completed'

    'connecting'
  end

  def claim_details
    {
      agent_binding_id: call_session.agent_binding_id,
      sip_profile_id: call_session.metadata.to_h.dig('operator_claim', 'sip_profile_id'),
      user_id: call_session.agent_binding&.user_id || operator_claim_user_id,
      user_name: claimed_user_name
    }.compact
  end

  def claim_payload
    {
      call_ref: call_session.external_call_ref,
      status: call_session.status,
      claimed: true,
      communication_thread_id: communication_thread_display_id,
      agent_ref: operator_agent_ref,
      agent_aor: operator_agent_aor,
      agent_binding_id: operator_agent_binding&.id,
      sip_profile_id: sip_profile&.id,
      user_id: user.id,
      user_name: user.name
    }.compact
  end

  def operator_agent_ref
    return operator_agent_binding.agent_ref if operator_agent_binding

    sip_profile&.agent_ref
  end

  def provider_owned_sip_provider?
    call_session.provider.to_s.in?(PROVIDER_OWNED_SIP_PROVIDERS)
  end

  def operator_agent_aor
    operator_agent_binding&.agent_aor || sip_profile&.agent_aor
  end

  def claimed_user_name
    call_session.metadata.to_h.dig('operator_claim', 'user_name').presence ||
      call_session.agent_binding&.user&.name ||
      account.users.find_by(id: operator_claim_user_id)&.name
  end

  def operator_claim_user_id
    call_session.metadata.to_h.dig('operator_claim', 'user_id').presence&.to_i
  end

  def broadcast_claimed_call!
    tokens = claimed_call_pubsub_tokens
    return if tokens.blank?

    event = {
      event: 'voice_call.claimed',
      data: claimed_call_realtime_payload
    }

    tokens.each { |token| ActionCable.server.broadcast(token, event) }
  rescue StandardError => e
    Rails.logger.warn(
      'TELEPHONY_OPERATOR_CLAIM_BROADCAST_FAILED ' \
      "call_ref=#{call_ref} account_id=#{account.id} user_id=#{user.id} error=#{e.class.name}: #{e.message}"
    )
  end

  def claimed_call_pubsub_tokens
    account.users.where(id: claimed_call_candidate_user_ids).filter_map(&:pubsub_token).uniq
  end

  def claimed_call_candidate_user_ids
    (
      [user.id] +
      related_claimed_call_sessions.flat_map { |session| candidate_user_ids_for_session(session) }
    ).compact.uniq
  end

  def candidate_user_ids_for_session(session)
    metadata = route_metadata_for_session(session)
    binding_ids = Array.wrap(metadata['operator_candidate_binding_ids']).filter_map { |value| value.presence&.to_i }
    sip_profile_ids = Array.wrap(metadata['operator_candidate_sip_profile_ids']).filter_map { |value| value.presence&.to_i }

    ids = Array.wrap(metadata['operator_candidate_user_ids']).filter_map { |value| value.presence&.to_i }
    ids << session.agent_binding&.user_id
    ids += account.telephony_agent_bindings.where(id: binding_ids).pluck(:user_id) if binding_ids.present?
    ids += account.telephony_sip_profiles.where(id: sip_profile_ids).pluck(:user_id) if sip_profile_ids.present?
    ids.compact.uniq
  end

  def related_claimed_call_sessions
    @related_claimed_call_sessions ||= begin
      target_started_at = call_session.started_at || call_session.created_at || Time.current
      candidates = account.telephony_call_sessions
                          .where(provider: call_session.provider, direction: call_session.direction)
                          .where(created_at: (target_started_at - 2.minutes)..(target_started_at + 2.minutes))
                          .to_a

      candidates.select { |session| session.id == call_session.id || related_claimed_call_session?(session) }
    end
  end

  def related_claimed_call_session?(session)
    return false unless session.direction == call_session.direction
    return false unless session.provider == call_session.provider

    current_key = logical_call_key_for_session(call_session)
    session_key = logical_call_key_for_session(session)
    current_key.present? && current_key == session_key
  end

  def logical_call_key_for_session(session)
    metadata = route_metadata_for_session(session)
    metadata['logical_call_key'].presence ||
      metadata['call_group_key'].presence ||
      metadata['logical_call_group_ref'].presence
  end

  def route_metadata_for_session(session)
    metadata = session.metadata || {}
    nested = metadata['metadata'] || metadata[:metadata] || {}
    nested.is_a?(Hash) ? nested.deep_stringify_keys : {}
  end

  def claimed_call_realtime_payload
    {
      account_id: account.id,
      call_sid: call_session.external_call_ref,
      callSid: call_session.external_call_ref,
      call_ref: call_session.external_call_ref,
      status: call_session.status,
      provider: call_session.provider,
      call_direction: call_session.direction,
      direction: call_session.direction,
      conversation_id: call_session.conversation&.display_id,
      conversation_display_id: call_session.conversation&.display_id,
      communication_thread_id: communication_thread_display_id,
      communicationThreadId: communication_thread_display_id,
      conversation_db_id: call_session.conversation_id,
      inbox_id: call_session.inbox_id,
      from_number: call_session.from_number,
      to_number: call_session.to_number,
      logical_call_key: logical_call_key_for_session(call_session),
      logicalCallKey: logical_call_key_for_session(call_session),
      related_call_sids: related_claimed_call_sessions.map(&:external_call_ref).uniq,
      relatedCallSids: related_claimed_call_sessions.map(&:external_call_ref).uniq,
      claimed_by_user_id: user.id,
      claimedByUserId: user.id,
      operator_claim: claim_payload
    }.compact
  end

  def communication_thread_display_id
    conversation = call_session.conversation
    return unless conversation&.account&.feature_enabled?('communication_threads')

    (conversation.communication_thread || conversation.refresh_communication_thread!)&.display_id
  end
end
