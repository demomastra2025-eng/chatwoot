class Telephony::OperatorCallAnsweredService
  def initialize(account:, user:, call_ref:, answered_at: nil)
    @account = account
    @user = user
    @call_ref = call_ref.to_s.strip
    @reported_answered_at = answered_at
  end

  def perform
    raise_call_ref_required! if call_ref.blank?
    raise_not_candidate! unless answerable_by_user?

    answered_session = Telephony::EventsIngestionService.new(payload: answered_event_payload).perform
    @call_session = answered_session || call_session.reload
    repair_completed_answer_state!

    {
      call_ref: call_session.external_call_ref,
      status: call_session.status,
      answered: true,
      answered_at: call_session.answered_at&.iso8601(3),
      user_id: user.id
    }
  end

  private

  attr_reader :account, :user, :call_ref, :reported_answered_at

  def call_session
    @call_session ||= account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def answerable_by_user?
    return false unless call_session.direction.in?(%w[inbound outbound])
    return false if call_session.terminal? && call_session.status != 'completed'
    return claimed_by_current_user? if call_session.direction == 'inbound'

    operator_user_ids.include?(user.id)
  end

  def operator_user_ids
    ids = Array.wrap(route_metadata['operator_candidate_user_ids']).filter_map { |value| value.presence&.to_i }
    ids << route_metadata['chatwoot_user_id'].presence&.to_i
    ids << call_session.agent_binding&.user_id
    ids << operator_claim_user_id
    ids.compact.uniq
  end

  def claimed_by_current_user?
    operator_claim_user_id == user.id || call_session.agent_binding&.user_id == user.id
  end

  def operator_claim_user_id
    call_session.metadata.to_h.dig('operator_claim', 'user_id').presence&.to_i
  end

  def route_metadata
    @route_metadata ||= begin
      metadata = call_session.metadata.to_h.deep_stringify_keys
      nested = metadata['metadata']
      nested.is_a?(Hash) ? nested.deep_stringify_keys : metadata
    end
  end

  def answered_event_payload
    timestamp = resolved_answered_at
    event_type = call_session.direction == 'inbound' ? 'operator_answered' : 'callee_answered'
    event_key = "webphone:#{event_type}:#{call_ref}:#{user.id}"
    {
      account_id: account.id,
      call_ref: call_ref,
      provider: call_session.provider,
      event: event_type,
      event_type: event_type,
      event_key: event_key,
      event_id: event_key,
      direction: call_session.direction,
      occurred_at: timestamp.iso8601(3),
      answered_at: timestamp.iso8601(3),
      answered_by: "user:#{user.id}",
      callee_leg_answered: call_session.direction == 'outbound',
      operator_leg_answered: call_session.direction == 'inbound',
      metadata: answered_event_metadata
    }
  end

  def answered_event_metadata
    {
      source: 'browser_janus_sip',
      route_action: 'operator',
      chatwoot_user_id: user.id
    }
  end

  def resolved_answered_at
    @resolved_answered_at ||= clamp_answered_at(parse_reported_answered_at || Time.current)
  end

  def clamp_answered_at(timestamp)
    lower_bound = call_session.started_at || call_session.created_at
    upper_bound = [call_session.ended_at, Time.current].compact.min
    return upper_bound if lower_bound > upper_bound

    timestamp.clamp(lower_bound, upper_bound)
  end

  def parse_reported_answered_at
    Time.zone.parse(reported_answered_at.to_s) if reported_answered_at.present?
  rescue ArgumentError, TypeError
    nil
  end

  def repair_completed_answer_state!
    call_session.with_lock do
      call_session.reload
      next unless call_session.status == 'completed'

      answered_at = call_session.answered_at || resolved_answered_at
      attributes = completed_answer_attributes(answered_at)
      call_session.update!(attributes) if attributes.present?
    end
  end

  def completed_answer_attributes(answered_at)
    attributes = {}
    attributes[:answered_at] = answered_at if call_session.answered_at.blank?
    attributes[:answered_by] = "user:#{user.id}" if call_session.answered_by.blank?

    if call_session.ended_at.present? && call_session.ended_at > answered_at
      attributes[:duration_seconds] = call_session.ended_at.to_i - answered_at.to_i
    end
    attributes
  end

  def raise_call_ref_required!
    raise Telephony::Error.new(
      code: 'CALL_REF_REQUIRED',
      message: 'call_ref is required',
      status: :unprocessable_content
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
