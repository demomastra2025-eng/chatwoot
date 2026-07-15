class Telephony::OperatorCallRejectService
  TERMINAL_STATUS_EVENT_TYPES = {
    'rejected' => 'rejected', 'completed' => 'session_completed',
    'no_answer' => 'operator_no_answer',
    'failed' => 'operator_failed',
    'cancelled' => 'caller_hangup'
  }.freeze

  def initialize(account:, user:, call_ref:, status: nil, reason: nil)
    @account = account
    @user = user
    @call_ref = call_ref.to_s.strip
    @status = Telephony::CallSession.normalize_status(status.presence || 'rejected') || 'rejected'
    @reason = reason.presence || default_reason
    @sipuni_termination_error = nil
  end

  def perform
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

    raise_invalid_status! unless TERMINAL_STATUS_EVENT_TYPES.key?(status)
    return ai_voice_release_ignored_payload if ai_voice_call?

    needs_ingestion = false
    should_terminate_remote = false
    call_session.with_lock do
      if call_session.terminal?
        validate_terminal_release!
        @terminal_completion_repair = terminal_completion_repair?
        needs_ingestion = @terminal_completion_repair
      else
        validate_release!
        should_terminate_remote = true
        apply_terminal_state!
        needs_ingestion = true
      end
    end

    request_provider_termination! if should_terminate_remote

    if needs_ingestion
      ingested_session = Telephony::EventsIngestionService.new(payload: reject_event_payload).perform
      @call_session = ingested_session
    end

    reject_payload
  end

  private

  attr_reader :account, :sipuni_termination_error, :user, :call_ref, :reason, :status

  def call_session
    @call_session ||= account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
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

  def operator_agent_ref
    return operator_agent_binding.agent_ref if operator_agent_binding

    sip_profile&.agent_ref
  end

  def operator_agent_aor
    operator_agent_binding&.agent_aor || sip_profile&.agent_aor
  end

  def rejectable_by_user?
    operator_route? && inbox_member? && candidate_binding? && candidate_sip_profile? && candidate_agent_ref? && candidate_user?
  end

  def validate_release!
    if outbound_operator_release?
      raise_not_candidate! unless outbound_release_allowed?
      return
    end

    raise_not_candidate! unless rejectable_by_user?
    raise_claimed_by_other! if claimed_by_other?
    raise_not_candidate! unless candidate_agent?
  end

  def validate_terminal_release!
    if outbound_operator_release?
      raise_not_candidate! unless outbound_release_allowed?
      return
    end

    raise_not_candidate! unless terminal_release_allowed?
    raise_claimed_by_other! if claimed_by_other?
  end

  def terminal_release_allowed?
    return false unless operator_route? && inbox_member?
    return false unless candidate_binding? && candidate_sip_profile? && candidate_agent_ref? && candidate_user?

    ended_by_current_user? || claimed_by_current_user? || candidate_user?
  end

  def ended_by_current_user?
    call_session.ended_by.to_s == "user:#{user.id}"
  end

  def outbound_call?
    call_session.direction == 'outbound'
  end

  def outbound_operator_release?
    outbound_call? && outbound_originated_from_chatwoot?
  end

  def outbound_originated_from_chatwoot?
    metadata = call_session.metadata.to_h.deep_stringify_keys
    return true if metadata['telephony_call_ref'].present?
    return true if metadata['sipuni_call_ref'].present?
    return true if outbound_route_metadata?
    return true if outbound_conversation_metadata?

    false
  end

  def outbound_route_metadata?
    outbound_values = %w[outbound to_pstn outbound_api outbound-dial outbound_api_call]
    outbound_values.include?(route_metadata['direction'].to_s.strip.downcase) ||
      outbound_values.include?(route_metadata['call_direction'].to_s.strip.downcase) ||
      outbound_values.include?(route_metadata['callDirection'].to_s.strip.downcase)
  end

  def outbound_conversation_metadata?
    attrs = (call_session.conversation&.additional_attributes || {}).deep_stringify_keys
    attrs['call_direction'].to_s == 'outbound' &&
      [
        attrs['telephony_call_ref'].to_s,
        attrs['sipuni_call_ref'].to_s,
        attrs['binotel_call_ref'].to_s,
        attrs['asterisk_analog_call_ref'].to_s,
        attrs['fonoster_call_ref'].to_s
      ].include?(call_session.external_call_ref.to_s)
  end

  def outbound_release_allowed?
    return false unless inbox_member?
    return true if call_session.agent_binding.blank?

    call_session.agent_binding.user_id == user.id
  end

  def operator_route?
    route_metadata['route_action'].to_s == 'operator' ||
      route_metadata['routing_mode'].to_s == 'operator' ||
      route_metadata['mode'].to_s == 'operator' ||
      route_metadata['operator_pool'].present? ||
      route_metadata['operator_candidates'].present? ||
      route_metadata['operator_candidate_binding_ids'].present? ||
      route_metadata['operator_candidate_sip_profile_ids'].present? ||
      route_metadata['operator_candidate_user_ids'].present? ||
      route_metadata['operator_candidate_agent_refs'].present? ||
      virtual_pbx_target_route? ||
      call_session.metadata.to_h['operator_claim'].present?
  end

  def ai_voice_call?
    metadata = call_session.metadata.to_h.deep_stringify_keys
    ai_metadata = metadata['ai_voice'].is_a?(Hash) ? metadata['ai_voice'] : {}

    route_metadata['route_action'].to_s == 'ai' ||
      route_metadata['routing_mode'].to_s == 'ai' ||
      route_metadata['mode'].to_s == 'ai' ||
      ai_metadata.present?
  end

  def inbox_member?
    return true if call_session.inbox.blank?
    return true unless call_session.inbox.inbox_members.exists?

    call_session.inbox.inbox_members.exists?(user_id: user.id)
  end

  def candidate_agent?
    # Once the operator has claimed a call, a remote BYE may mark the browser
    # SIP profile offline before the release request reaches Rails. The claim
    # remains authoritative for releasing that call.
    return true if claimed_by_current_user?

    return agent_binding.enabled? && agent_binding.registered_for_routing? if operator_identity.is_a?(Telephony::AgentBinding)

    sip_profile.present? && sip_profile.registered_for_routing?
  end

  def terminal_completion_repair?
    return false unless status == 'completed' && call_session.status != 'completed'

    call_session.answered_at.present? ||
      call_session.recording_ref.present? ||
      Array.wrap(call_session.legs).any? do |leg|
        leg.is_a?(Hash) && leg.deep_stringify_keys['status'].to_s == 'in_progress'
      end
  end

  def candidate_binding?
    candidate_binding_ids = operator_candidate_binding_ids
    return true if candidate_binding_ids.blank?

    candidate_binding_ids.include?(operator_agent_binding&.id)
  end

  def candidate_sip_profile?
    candidate_sip_profile_ids = operator_candidate_sip_profile_ids
    return true if candidate_sip_profile_ids.blank?

    candidate_sip_profile_ids.include?(sip_profile&.id)
  end

  def candidate_agent_ref?
    candidate_agent_refs = operator_candidate_agent_refs
    return true if candidate_agent_refs.blank?

    candidate_agent_refs.include?(operator_agent_ref)
  end

  def candidate_user?
    candidate_user_ids = operator_candidate_user_ids
    return true if candidate_user_ids.blank?

    candidate_user_ids.include?(user.id)
  end

  def claimed_by_other?
    return !claimed_by_current_user? if call_session.agent_binding_id.present?

    operator_claim_user_id.present? && operator_claim_user_id != user.id
  end

  def claimed_by_current_user?
    return call_session.agent_binding_id == operator_agent_binding&.id if call_session.agent_binding_id.present?

    operator_claim_user_id == user.id
  end

  def operator_claim_user_id
    call_session.metadata.to_h.dig('operator_claim', 'user_id').presence&.to_i
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

  def apply_terminal_state!
    call_session.update!(
      status: status,
      ended_at: Time.current,
      ended_by: "user:#{user.id}",
      end_reason: reason,
      last_event_at: Time.current
    )
  end

  def request_provider_termination!
    request_sipuni_hangup! if sipuni_hangup_required?
  end

  def request_sipuni_hangup!
    Telephony::Sipuni::ApiClient.new.hangup(call_id: sipuni_provider_call_id)
  rescue Telephony::Error => e
    @sipuni_termination_error = e.code
    Rails.logger.warn(
      'TELEPHONY_OPERATOR_REJECT_SIPUNI_HANGUP_FAILED ' \
      "account_id=#{account.id} call_ref=#{call_ref} provider_call_sid=#{sipuni_provider_call_id} " \
      "error_code=#{e.code} message=#{e.message}"
    )
    nil
  end

  def sipuni_hangup_required?
    call_session.provider == 'sipuni' && sipuni_provider_call_id.present?
  end

  def sipuni_provider_call_id
    provider_call_sid = call_session.provider_call_sid.presence
    return provider_call_sid if provider_call_sid.present?
    return if janus_sip_call_ref?

    call_session.external_call_ref.to_s.match(/\Asipuni:(?!local:)(.+)\z/)&.[](1)
  end

  def janus_sip_call_ref?
    call_session.external_call_ref.to_s.match?(/\A(?:asterisk_analog|binotel|sipuni):janus:/)
  end

  def reject_event_payload
    ended_at = release_ended_at.iso8601(3)
    {
      account_id: account.id,
      call_ref: call_ref,
      event_key: reject_event_key,
      event_id: reject_event_key,
      event_type: TERMINAL_STATUS_EVENT_TYPES.fetch(status),
      status: status,
      direction: call_session.direction,
      ended_at: ended_at,
      ended_by: "user:#{user.id}",
      reason: reason,
      metadata: release_metadata
    }
  end

  def release_ended_at
    return Time.current unless @terminal_completion_repair

    if call_session.answered_at.present? && call_session.duration_seconds.to_i.positive?
      return call_session.answered_at + call_session.duration_seconds.seconds
    end

    call_session.ended_at || Time.current
  end

  def reject_event_key
    "webphone:#{status}:#{call_ref}:#{user.id}"
  end

  def release_metadata
    {
      chatwoot_user_id: user.id,
      route_action: route_metadata['route_action'],
      webphone_action: 'operator_release',
      release_status: status,
      release_reason: reason,
      sipuni_termination_error: sipuni_termination_error
    }.compact
  end

  def reject_payload
    {
      call_ref: call_session.external_call_ref,
      status: call_session.status,
      released: true,
      reason: reason,
      user_id: user.id
    }
  end

  def ai_voice_release_ignored_payload
    {
      call_ref: call_session.external_call_ref,
      status: call_session.status,
      released: false,
      ignored: true,
      reason: 'ai_voice_call',
      user_id: user.id
    }
  end

  def default_reason
    { 'completed' => 'operator_hangup', 'no_answer' => 'browser_webphone_not_ready' }.fetch(status, 'operator_rejected_from_browser')
  end

  def raise_invalid_status!
    raise Telephony::Error.new(
      code: 'INVALID_RELEASE_STATUS',
      message: 'Unsupported call release status',
      status: :unprocessable_content,
      details: { status: status }
    )
  end

  def raise_not_candidate!
    raise Telephony::Error.new(
      code: 'OPERATOR_NOT_CANDIDATE',
      message: 'Current user is not an operator candidate for this call',
      status: :forbidden
    )
  end

  def raise_claimed_by_other!
    raise Telephony::Error.new(
      code: 'CALL_ALREADY_CLAIMED',
      message: 'Call was already claimed by another operator',
      status: :conflict,
      details: {
        agent_binding_id: call_session.agent_binding_id,
        sip_profile_id: call_session.metadata.to_h.dig('operator_claim', 'sip_profile_id'),
        user_id: call_session.agent_binding&.user_id || operator_claim_user_id
      }.compact
    )
  end
end
