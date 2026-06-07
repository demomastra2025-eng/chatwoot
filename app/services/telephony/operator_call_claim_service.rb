class Telephony::OperatorCallClaimService
  def initialize(account:, user:, call_ref:)
    @account = account
    @user = user
    @call_ref = call_ref.to_s.strip
  end

  def perform
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

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

    claim_payload
  end

  private

  attr_reader :account, :user, :call_ref

  def call_session
    @call_session ||= account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def agent_binding
    @agent_binding ||= account.telephony_agent_bindings.find_by(user_id: user.id)
  end

  def candidate_user?
    return false unless operator_route?
    return false unless agent_binding&.enabled? && agent_binding.registered_for_routing?
    return false unless inbox_member?
    return false unless candidate_binding_id?
    return false unless candidate_agent_ref?

    candidate_user_id?
  end

  def candidate_binding_id?
    candidate_binding_ids = operator_candidate_binding_ids
    candidate_binding_ids.blank? || candidate_binding_ids.include?(agent_binding&.id)
  end

  def candidate_agent_ref?
    candidate_agent_refs = operator_candidate_agent_refs
    candidate_agent_refs.blank? || candidate_agent_refs.include?(agent_binding&.agent_ref)
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
      route_metadata['operator_candidate_agent_refs'].present?
  end

  def inbox_member?
    return true if call_session.inbox.blank?
    return true unless call_session.inbox.inbox_members.exists?

    call_session.inbox.inbox_members.exists?(user_id: user.id)
  end

  def operator_candidate_binding_ids
    Array.wrap(route_metadata['operator_candidate_binding_ids']).filter_map { |value| value.presence&.to_i }
  end

  def operator_candidate_agent_refs
    Array.wrap(route_metadata['operator_candidate_agent_refs']).filter_map { |value| value.presence&.to_s }
  end

  def operator_candidate_user_ids
    Array.wrap(route_metadata['operator_candidate_user_ids']).filter_map { |value| value.presence&.to_i }
  end

  def route_metadata
    @route_metadata ||= begin
      metadata = call_session.metadata || {}
      nested = metadata['metadata'] || metadata[:metadata] || {}
      nested.is_a?(Hash) ? nested.deep_stringify_keys : {}
    end
  end

  def claimed_by_other?
    return false if call_session.agent_binding_id.blank?

    call_session.agent_binding_id != agent_binding.id
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
      agent_binding_id: agent_binding&.id,
      agent_ref: agent_binding&.agent_ref,
      registered_for_routing: agent_binding&.registered_for_routing?,
      inbox_id: call_session.inbox_id
    }

    base.merge(registration_details).compact
  end

  def not_candidate_reason
    return 'call_not_operator_route' unless operator_route?
    return 'operator_binding_missing' if agent_binding.blank?
    return 'operator_binding_disabled' unless agent_binding.enabled?
    return 'operator_not_registered' unless agent_binding.registered_for_routing?
    return 'operator_not_in_inbox' unless inbox_member?
    return 'operator_binding_not_in_candidate_pool' unless candidate_binding_id?
    return 'operator_agent_ref_not_in_candidate_pool' unless candidate_agent_ref?
    return 'operator_user_not_in_candidate_pool' unless candidate_user_id?

    'operator_not_candidate'
  end

  def registration_details
    telephony = agent_binding&.to_telephony_h || {}
    {
      registration_state: telephony[:registration_state],
      last_presence_source: telephony[:last_presence_source],
      last_presence_event_at: telephony[:last_presence_event_at],
      last_synced_at: telephony[:last_synced_at]&.iso8601
    }
  end

  def claim_call!
    call_session.update!(
      agent_binding: agent_binding,
      answered_by: call_session.answered_by || "user:#{user.id}",
      status: claim_status,
      metadata: (call_session.metadata || {}).deep_merge(
        'operator_claim' => {
          'agent_binding_id' => agent_binding.id,
          'agent_ref' => agent_binding.agent_ref,
          'agent_aor' => agent_binding.agent_aor,
          'user_id' => user.id,
          'claimed_at' => Time.current.iso8601
        }
      )
    )
  end

  def claim_status
    return call_session.status if call_session.status == 'in_progress' || call_session.status == 'completed'

    'connecting'
  end

  def claim_details
    {
      agent_binding_id: call_session.agent_binding_id,
      user_id: call_session.agent_binding&.user_id
    }.compact
  end

  def claim_payload
    {
      call_ref: call_session.external_call_ref,
      status: call_session.status,
      claimed: true,
      agent_ref: agent_binding.agent_ref,
      agent_aor: agent_binding.agent_aor,
      agent_binding_id: agent_binding.id,
      user_id: user.id
    }
  end
end
