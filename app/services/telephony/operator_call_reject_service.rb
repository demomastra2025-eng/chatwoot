class Telephony::OperatorCallRejectService
  TERMINAL_STATUS_EVENT_TYPES = {
    'rejected' => 'rejected',
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
  end

  def perform
    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content) if call_ref.blank?

    raise_invalid_status! unless TERMINAL_STATUS_EVENT_TYPES.key?(status)

    terminal_call = false
    call_session.with_lock do
      raise_not_candidate! unless rejectable_by_user?
      terminal_call = call_session.terminal?
    end

    unless terminal_call
      ingested_session = Telephony::EventsIngestionService.new(payload: reject_event_payload).perform
      @call_session = ingested_session
    end

    reject_payload
  end

  private

  attr_reader :account, :user, :call_ref, :reason, :status

  def call_session
    @call_session ||= account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def rejectable_by_user?
    operator_route? && inbox_member? && candidate_user?
  end

  def operator_route?
    route_metadata['route_action'].to_s == 'operator' ||
      route_metadata['operator_pool'].present? ||
      route_metadata['operator_candidates'].present? ||
      route_metadata['operator_candidate_user_ids'].present? ||
      route_metadata['operator_candidate_agent_refs'].present? ||
      call_session.metadata.to_h['operator_claim'].present?
  end

  def inbox_member?
    return true if call_session.inbox.blank?
    return true unless call_session.inbox.inbox_members.exists?

    call_session.inbox.inbox_members.exists?(user_id: user.id)
  end

  def candidate_user?
    candidate_user_ids = operator_candidate_user_ids
    return true if candidate_user_ids.blank?

    candidate_user_ids.include?(user.id)
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

  def reject_event_payload
    now = Time.current.iso8601
    {
      account_id: account.id,
      call_ref: call_ref,
      event_key: reject_event_key,
      event_id: reject_event_key,
      event_type: TERMINAL_STATUS_EVENT_TYPES.fetch(status),
      status: status,
      direction: call_session.direction,
      ended_at: now,
      ended_by: "user:#{user.id}",
      reason: reason,
      metadata: release_metadata
    }
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
      release_reason: reason
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

  def default_reason
    status == 'no_answer' ? 'browser_webphone_not_ready' : 'operator_rejected_from_browser'
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
end
