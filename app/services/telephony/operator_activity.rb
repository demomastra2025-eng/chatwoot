# The quiet "operator X is calling / talking" line other operators see in the
# conversation. It carries only the operator's name and the state of the call:
# no phone numbers and no contact data. One call session of one operator.
class Telephony::OperatorActivity
  EVENT = 'voice_call.operator_activity'.freeze

  STATE_CALLING = 'calling'.freeze
  STATE_TALKING = 'talking'.freeze
  STATE_ENDED = 'ended'.freeze

  PRE_ANSWER_STATUSES = %w[created ringing connecting].freeze
  # An outbound call cannot ring longer than this; a "calling" line older than
  # that is a lost event, never a live call.
  MAX_CALLING_AGE = 3.minutes
  # A little above the longest call the channel allows (240 minutes).
  MAX_TALKING_AGE = 250.minutes

  attr_reader :call_session

  def initialize(call_session)
    @call_session = call_session
  end

  # The state a line should show right now, or nil when nothing is to be shown.
  def state
    status = call_session.canonical_status
    return STATE_ENDED if call_session.terminal?
    return STATE_TALKING if status == 'in_progress'
    return STATE_CALLING if outbound? && PRE_ANSWER_STATUSES.include?(status)

    nil
  end

  # Payload of the realtime event and of the "what is going on" fetch.
  def payload
    return if call_session.conversation.blank? || operator.blank?

    current_state = state
    return if current_state.blank?

    {
      account_id: call_session.account_id,
      call_id: call_session.external_call_ref,
      conversation_id: call_session.conversation.display_id,
      communication_thread_id: communication_thread_display_id,
      operator_user_id: operator.id,
      operator_name: operator_name,
      state: current_state
    }.compact
  end

  # Same as payload, but only for a call that is really on right now.
  def live_payload
    return unless live?

    payload
  end

  def live?
    case state
    when STATE_CALLING then recent?(call_session.started_at || call_session.created_at, MAX_CALLING_AGE)
    when STATE_TALKING then recent?(call_session.answered_at || call_session.last_event_at || call_session.created_at, MAX_TALKING_AGE)
    else false
    end
  end

  def operator
    return @operator if defined?(@operator)

    @operator = call_session.account.users.find_by(id: operator_user_id) if operator_user_id.present?
  end

  private

  def outbound?
    call_session.direction == 'outbound'
  end

  def recent?(timestamp, max_age)
    timestamp.present? && timestamp > max_age.ago
  end

  def operator_user_id
    @operator_user_id ||= claim_user_id || (outbound? ? outbound_owner_user_id : nil) || call_session.agent_binding&.user_id
  end

  def claim_user_id
    claim = metadata['operator_claim']
    claim.is_a?(Hash) ? claim['user_id'].presence&.to_i : nil
  end

  # An outbound call belongs to the operator who started it.
  def outbound_owner_user_id
    route = metadata['metadata'].is_a?(Hash) ? metadata['metadata'] : {}
    route['chatwoot_user_id'].presence&.to_i ||
      Array.wrap(route['operator_candidate_user_ids']).filter_map { |value| value.presence&.to_i }.first
  end

  def metadata
    @metadata ||= call_session.metadata.to_h.deep_stringify_keys
  end

  def operator_name
    operator.display_name.presence || operator.name
  end

  def communication_thread_display_id
    conversation = call_session.conversation
    return unless conversation.account&.feature_enabled?('communication_threads')

    conversation.communication_thread&.display_id
  end
end
