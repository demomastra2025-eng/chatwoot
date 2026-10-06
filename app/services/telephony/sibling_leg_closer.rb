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

  # An operator browser may report its leg after another operator took the
  # call (the claim closes only the legs that exist at that instant). Such a leg
  # is closed as soon as it is admitted, before it rings. Nothing changes for a
  # call nobody owns, or whose owner is over: that is a call that rings.
  #
  # Only the late leg is closed. The owner found here may be the claim fence
  # (the oldest leg, which carries a copy of the claim) and not the leg of the
  # operator who really took the call; closing "every other leg" from it would
  # close the claimer's own leg while the claimer's closer has not run yet.
  # For the same reason the late leg of the claimer himself is never closed: it
  # is his own report arriving again, or racing his claim (see close_only!).
  def self.close_late_leg(leg)
    return leg unless Telephony::SiblingLegGrouping.applies?(provider: leg.provider, direction: leg.direction)
    return leg if leg.terminal?

    owner = Telephony::SiblingLegGrouping.owner_leg(leg, except: leg)
    return leg if owner.blank?

    new(call_session: owner).close_only!(leg)
    leg.reload
  end

  def initialize(call_session:)
    @call_session = call_session
  end

  # Under the caller's intake lock: a leg that is being admitted at this very
  # moment is either visible here or sees the claim and closes itself.
  def perform
    return [] unless answered_leg?

    Telephony::CallIntakeLock.with_lock(account_id: call_session.account_id, phone_number: call_session.from_number) do
      open_sibling_legs.filter_map { |sibling| close_leg!(sibling) }
    end
  end

  # Closes this one leg of the group and leaves the others alone. A leg that
  # belongs to the operator who took the call stays: its routing decision may
  # have been taken before the claim committed, and closing it would leave the
  # call with nobody to talk.
  def close_only!(leg)
    return unless answered_leg? && closable_leg?(leg) && !winner_leg?(leg)

    Telephony::CallIntakeLock.with_lock(account_id: call_session.account_id, phone_number: call_session.from_number) do
      close_leg!(leg)
    end
  end

  private

  attr_reader :call_session

  def answered_leg?
    Telephony::SiblingLegGrouping.applies?(provider: call_session.provider, direction: call_session.direction) &&
      %w[connecting in_progress].include?(call_session.canonical_status)
  end

  def open_sibling_legs
    call_session.logical_group_sessions.select { |leg| closable_leg?(leg) }
  end

  def closable_leg?(leg)
    leg.id != call_session.id &&
      leg.account_id == call_session.account_id &&
      leg.provider == call_session.provider &&
      leg.direction == 'inbound' &&
      leg.answered_at.blank? &&
      OPEN_STATUSES.include?(leg.canonical_status)
  end

  def winner_leg?(leg)
    winner = winner_user_id
    winner.present? && leg_operator_id(leg) == winner
  end

  # The operator a browser leg was reported by (route metadata of the report).
  def leg_operator_id(leg)
    route = route_metadata(leg)
    return route['target_user_id'].to_i if route['target_user_id'].present?

    profile_id = route['telephony_sip_profile_id'].presence || route['target_sip_profile_id'].presence
    leg.account.telephony_sip_profiles.find_by(id: profile_id)&.user_id if profile_id
  end

  def close_leg!(sibling)
    # A savepoint: a failed leg must not poison the transaction of the others.
    Telephony::CallSession.transaction(requires_new: true) do
      Telephony::EventsIngestionService.new(payload: close_event_payload(sibling)).perform
    end
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
