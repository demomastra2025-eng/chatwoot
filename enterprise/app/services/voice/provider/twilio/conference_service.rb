class Voice::Provider::Twilio::ConferenceService
  # The agent who joined the conference owns the call. Nobody else may take the
  # call over while it is live, and nobody else may end it.
  class NotCallOwner < StandardError; end

  pattr_initialize [:conversation!, { twilio_client: nil }]

  def ensure_conference_sid
    existing = conversation.additional_attributes&.dig('conference_sid')
    return existing if existing.present?

    sid = Voice::Conference::Name.for(conversation)
    merge_attributes('conference_sid' => sid)
    sid
  end

  # Joining is decided under the conversation row lock, so two agents that join
  # at the same time end with exactly one owner.
  def mark_agent_joined(user:)
    with_locked_conversation do
      raise NotCallOwner, 'Call joined by another agent' if live_owner_other_than?(user)

      merge_attributes(
        'agent_joined' => true,
        'joined_at' => Time.current.to_i,
        'joined_by' => { id: user.id, name: user.name }
      )
    end
  end

  # With a user the owner check is made on the freshly locked conversation: the
  # decision to end the conference is taken in the same protected step as the
  # check. Without a user (system) the conference is ended unconditionally.
  def end_conference(user: nil)
    ensure_owner!(user) if user

    twilio_client
      .conferences
      .list(friendly_name: Voice::Conference::Name.for(conversation), status: 'in-progress')
      .each { |conf| twilio_client.conferences(conf.sid).update(status: 'completed') }
  end

  private

  def ensure_owner!(user)
    with_locked_conversation do
      owner_id = joined_agent_id
      raise NotCallOwner, 'Call joined by another agent' if owner_id.present? && owner_id != user.id
    end
  end

  # Row lock on the freshly read conversation: what the check sees is what is
  # stored now, whatever the object held when the service was built.
  def with_locked_conversation(&)
    conversation.transaction do
      conversation.reload(lock: true)
      yield
    end
  end

  def live_owner_other_than?(user)
    owner_id = joined_agent_id
    owner_id.present? && owner_id != user.id && owner_call_live?
  end

  def joined_agent_id
    joined_by = conversation.additional_attributes&.dig('joined_by')
    joined_by.is_a?(Hash) ? joined_by['id']&.to_i : nil
  end

  # The recorded owner still holds the call unless the call is over, or the
  # conversation has since started a new call that the owner has not joined.
  def owner_call_live?
    attrs = conversation.additional_attributes || {}
    status = Telephony::CallSession.normalize_status(attrs['call_status'])
    return false if Telephony::CallSession::TERMINAL_STATUSES.include?(status)

    initiated_at = attrs.dig('meta', 'initiated_at')
    joined_at = attrs['joined_at']
    return false if initiated_at.present? && joined_at.present? && joined_at.to_i < initiated_at.to_i

    true
  end

  def merge_attributes(attrs)
    current = conversation.additional_attributes || {}
    conversation.update!(additional_attributes: current.merge(attrs))
  end

  def twilio_client
    @twilio_client ||= ::Twilio::REST::Client.new(account_sid, auth_token)
  end

  def account_sid
    @account_sid ||= conversation.inbox.channel.provider_config_hash['account_sid']
  end

  def auth_token
    @auth_token ||= conversation.inbox.channel.provider_config_hash['auth_token']
  end
end
