# When one operator takes a call, the legs the other operators' browsers
# reported for the same physical call are over for them. Without this they
# stay "ringing" until the browser reports a hangup, or until the
# reconciliation closes them minutes later, and their cards linger.
#
# Each open sibling leg is closed as a no answer with the end reason
# answered_by_other_operator through the normal ingestion path: the status
# broadcast, the voice message sync and the suppression of unanswered legs of
# an answered call (it is not a missed call) are the existing ones. Replaying
# it changes nothing: closed legs are skipped and the event key is per leg.
class Telephony::SiblingLegCloser
  END_REASON = 'answered_by_other_operator'.freeze
  # "connecting" is included: a claim is copied onto the oldest leg of the
  # group (the claim fence), which is not the leg that answered.
  OPEN_STATUSES = %w[created ringing connecting].freeze

  def initialize(call_session:)
    @call_session = call_session
  end

  def perform
    return [] unless answered_leg?

    open_sibling_legs.filter_map { |sibling| close_leg!(sibling) }
  end

  private

  attr_reader :call_session

  def answered_leg?
    Telephony::SiblingLegGrouping.applies?(provider: call_session.provider, direction: call_session.direction) &&
      %w[connecting in_progress].include?(call_session.canonical_status)
  end

  def open_sibling_legs
    call_session.logical_group_sessions.select do |leg|
      leg.id != call_session.id &&
        leg.account_id == call_session.account_id &&
        leg.provider == call_session.provider &&
        leg.direction == 'inbound' &&
        leg.answered_at.blank? &&
        OPEN_STATUSES.include?(leg.canonical_status)
    end
  end

  def close_leg!(sibling)
    Telephony::EventsIngestionService.new(payload: close_event_payload(sibling)).perform
    sibling.reload
    broadcast_claimed!(sibling)
    sibling
  rescue StandardError => e
    Rails.logger.warn(
      "TELEPHONY_SIBLING_LEG_CLOSE_FAILED call_ref=#{sibling.external_call_ref} " \
      "account_id=#{sibling.account_id} error=#{e.class.name}: #{e.message}"
    )
    nil
  end

  def close_event_payload(sibling)
    closed_at = Time.current.iso8601(3)
    event_key = "#{END_REASON}:#{sibling.external_call_ref}"
    {
      account_id: sibling.account_id,
      call_ref: sibling.external_call_ref,
      provider: sibling.provider,
      event: 'operator_no_answer',
      event_type: 'operator_no_answer',
      event_key: event_key,
      event_id: event_key,
      status: 'no_answer',
      direction: 'inbound',
      occurred_at: closed_at,
      ended_at: closed_at,
      ended_by: 'system',
      end_reason: END_REASON,
      metadata: { source: END_REASON, answered_call_ref: call_session.external_call_ref }
    }
  end

  # The operator the leg belongs to learns at once that somebody else took the
  # call: the same event every claimed call sends, addressed to the leg.
  def broadcast_claimed!(sibling)
    tokens = sibling_user_tokens(sibling)
    return if tokens.blank?

    event = { event: 'voice_call.claimed', data: claimed_payload(sibling) }
    tokens.each { |token| ActionCable.server.broadcast(token, event) }
  rescue StandardError => e
    Rails.logger.warn(
      "TELEPHONY_SIBLING_LEG_CLAIM_BROADCAST_FAILED call_ref=#{sibling.external_call_ref} " \
      "account_id=#{sibling.account_id} error=#{e.class.name}: #{e.message}"
    )
  end

  def sibling_user_tokens(sibling)
    user_ids = sibling_user_ids(sibling) - [winner_user_id].compact

    sibling.account.users.where(id: user_ids).filter_map(&:pubsub_token).uniq
  end

  def sibling_user_ids(sibling)
    route = route_metadata(sibling)
    profile_ids = Array.wrap(route['operator_candidate_sip_profile_ids']) +
                  [route['target_sip_profile_id'], route['telephony_sip_profile_id']]
    user_ids = Array.wrap(route['operator_candidate_user_ids']) + [route['target_user_id']] +
               sibling.account.telephony_sip_profiles.where(id: profile_ids.compact_blank).pluck(:user_id)
    user_ids.compact_blank.map(&:to_i).uniq
  end

  def claimed_payload(sibling)
    {
      account_id: sibling.account_id,
      call_sid: sibling.external_call_ref,
      callSid: sibling.external_call_ref,
      call_ref: sibling.external_call_ref,
      status: call_session.canonical_status,
      provider: sibling.provider,
      call_direction: 'inbound',
      direction: 'inbound',
      conversation_db_id: sibling.conversation_id,
      inbox_id: sibling.inbox_id,
      from_number: sibling.from_number,
      to_number: sibling.to_number
    }.merge(claimed_group_payload).compact
  end

  def claimed_group_payload
    key = call_session.canonical_logical_call_key.presence || call_session.logical_call_group_ref
    related_refs = call_session.logical_group_sessions.map(&:external_call_ref).uniq
    {
      logical_call_key: key,
      logicalCallKey: key,
      related_call_sids: related_refs,
      relatedCallSids: related_refs,
      claimed_by_user_id: winner_user_id,
      claimedByUserId: winner_user_id,
      operator_claim: winner_claim
    }
  end

  def winner_claim
    claim = call_session.metadata.to_h.deep_stringify_keys['operator_claim']
    claim.is_a?(Hash) ? claim : {}
  end

  def winner_user_id
    winner_claim['user_id'].presence&.to_i ||
      call_session.answered_by.to_s[/\Auser:(\d+)\z/, 1]&.to_i ||
      call_session.agent_binding&.user_id
  end

  def route_metadata(session)
    route = session.metadata.to_h.deep_stringify_keys['metadata']
    route.is_a?(Hash) ? route : {}
  end
end
