class CommunicationThreads::ParticipationService
  def initialize(communication_thread:, actor: Current.user)
    @communication_thread = communication_thread
    @actor = actor
  end

  def add!(user_id:, reason: 'manual_add', idempotency_key: nil, correlation_id: nil) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    participant_user = active_workspace_user!(user_id)
    raise ArgumentError, 'assignee cannot also be a participant' if communication_thread.assignee_id == participant_user.id

    CommunicationThreadParticipantLifecycleFact.validate_actor!(actor: actor, account_id: communication_thread.account_id)

    created = false
    membership = CommunicationThreadParticipant.transaction do
      communication_thread.lock!
      if idempotency_key.present? && fact_replay?(idempotency_key, participant_id: participant_user.id, action: 'add')
        next communication_thread.communication_thread_participants.find_by(user_id: participant_user.id)
      end

      record = CommunicationThreadParticipant.find_or_create_for!(
        communication_thread: communication_thread,
        user_id: participant_user.id,
        added_by: membership_added_by,
        audit_comment: reason
      )
      if record.previously_new_record?
        identity = operation_identity(idempotency_key, correlation_id, fallback_key: "membership:#{record.id}:add")
        CommunicationThreadParticipantLifecycleFact.record!(
          membership: record, actor: actor, action: 'add', reason: reason, identity: identity
        )
        create_activity!(:added, participant_user, reason)
        created = true
      end
      record
    end
    enqueue_realtime!(recipient_user_ids: [participant_user.id]) if created
    membership
  end

  def remove!(user_id:, reason: 'manual_remove', idempotency_key: nil, correlation_id: nil)
    participant_user = nil
    membership = CommunicationThreadParticipant.transaction do
      communication_thread.lock!
      action = action_for(reason)
      next if idempotency_key.present? && fact_replay?(idempotency_key, participant_id: user_id, action: action)

      record = communication_thread.communication_thread_participants.find_by(user_id: user_id)
      next if record.blank? && completed_removal_exists?(user_id, action, reason)

      raise ActiveRecord::RecordNotFound if record.blank?

      identity = operation_identity(idempotency_key, correlation_id, fallback_key: "membership:#{record.id}:#{action}")
      participant_user = record.user
      destroy_membership!(record, participant_user, reason, action: action, identity: identity)
      record
    end
    enqueue_realtime!(recipient_user_ids: [participant_user.id]) if participant_user
    membership
  end

  def clear!(reason: 'participants_cleared', idempotency_key: nil, correlation_id: nil)
    correlation_id ||= SecureRandom.uuid
    removed_user_ids = CommunicationThreadParticipant.transaction do
      communication_thread.lock!
      communication_thread.communication_thread_participants.includes(:user).filter_map do |membership|
        participant_user = membership.user
        action = action_for(reason, fallback: 'clear')
        event_key = "#{idempotency_key}:#{participant_user.id}" if idempotency_key.present?
        event_identity = operation_identity(event_key, correlation_id, fallback_key: "membership:#{membership.id}:#{action}")
        next if fact_replay?(event_identity[:key], participant_id: participant_user.id, action: action)

        destroy_membership!(membership, participant_user, reason, action: action, identity: event_identity)
        participant_user.id
      end
    end
    enqueue_realtime!(recipient_user_ids: removed_user_ids) if removed_user_ids.any?
  end

  def retain!(user_ids:, reason: 'participation_scope_changed', idempotency_key: nil, correlation_id: nil) # rubocop:disable Metrics/AbcSize
    retained_ids = Array(user_ids).map(&:to_i)
    correlation_id ||= SecureRandom.uuid
    removed_user_ids = CommunicationThreadParticipant.transaction do
      communication_thread.lock!
      communication_thread.communication_thread_participants.where.not(user_id: retained_ids).includes(:user).filter_map do |membership|
        participant_user = membership.user
        action = action_for(reason, fallback: 'retain')
        event_key = "#{idempotency_key}:#{participant_user.id}" if idempotency_key.present?
        event_identity = operation_identity(event_key, correlation_id, fallback_key: "membership:#{membership.id}:#{action}")
        next if fact_replay?(event_identity[:key], participant_id: participant_user.id, action: action)

        destroy_membership!(membership, participant_user, reason, action: action, identity: event_identity)
        participant_user.id
      end
    end
    enqueue_realtime!(recipient_user_ids: removed_user_ids) if removed_user_ids.any?
  end

  private

  attr_reader :communication_thread, :actor

  def active_workspace_user!(user_id)
    account_user = communication_thread.account.account_users.find_by!(user_id: user_id)
    raise ActiveRecord::RecordNotFound unless account_user.user.confirmed?

    account_user.user
  end

  def create_activity!(event, participant_user, reason)
    conversation = primary_conversation
    return if conversation.blank?

    conversation.messages.create!(
      account_id: communication_thread.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: activity_content(event, participant_user),
      content_attributes: {
        communication_thread_participation: {
          event: event.to_s,
          thread_id: communication_thread.display_id,
          participant_id: participant_user.id,
          participant_name: participant_user.name,
          actor_id: actor&.id,
          actor_name: actor&.name,
          reason: reason
        }
      }
    )
  end

  def primary_conversation
    link = communication_thread.communication_thread_conversations.includes(:conversation).find_by(primary: true)
    link ||= communication_thread.communication_thread_conversations.includes(:conversation).order(:id).first
    link&.conversation
  end

  def activity_content(event, participant_user)
    actor_name = actor&.name || 'System'
    action = event == :added ? 'added' : 'removed'
    "#{actor_name} #{action} #{participant_user.name} #{event == :added ? 'as a participant' : 'from participants'}"
  end

  def destroy_membership!(membership, participant_user, reason, action:, identity:)
    membership.audit_comment = reason
    membership.lifecycle_fact_context = { actor: actor, action: action, reason: reason, identity: identity }
    membership.destroy!
    create_activity!(:removed, participant_user, reason)
  end

  def operation_identity(idempotency_key, correlation_id, fallback_key:)
    correlation_id = correlation_id.presence || SecureRandom.uuid
    { key: idempotency_key.presence || fallback_key, correlation_id: correlation_id, occurred_at: Time.current }
  end

  def fact_replay?(idempotency_key, participant_id:, action:)
    fact = CommunicationThreadParticipantLifecycleFact.find_by(
      account_id: communication_thread.account_id,
      idempotency_key: idempotency_key
    )
    return false if fact.blank?
    return true if fact.communication_thread_id == communication_thread.id && fact.participant_id == participant_id.to_i && fact.action == action

    raise ArgumentError, 'idempotency key was already used for another participant lifecycle operation'
  end

  def completed_removal_exists?(participant_id, action, reason)
    CommunicationThreadParticipantLifecycleFact.exists?(
      account_id: communication_thread.account_id,
      communication_thread_id: communication_thread.id,
      participant_id: participant_id,
      action: action,
      reason: reason
    )
  end

  def action_for(reason, fallback: 'remove')
    {
      'participants_cleared' => 'clear',
      'participation_scope_changed' => 'retain',
      'cross_team_transfer' => 'retain',
      'promoted_to_owner' => 'promote',
      'thread_resolved' => 'resolve'
    }.fetch(reason.to_s, fallback)
  end

  def membership_added_by
    actor if actor.is_a?(User)
  end

  def enqueue_realtime!(recipient_user_ids: [])
    conversation = primary_conversation
    return if conversation.blank?

    payload = {
      communication_thread_id: communication_thread.id,
      source_conversation_id: conversation.id,
      source_event: 'communication_thread.participants_changed',
      performer_id: actor&.id,
      recipient_user_ids: recipient_user_ids
    }
    CommunicationThreads::AfterCommit.run do
      CommunicationThreads::RealtimeUpdateJob.perform_later(**payload)
    end
  end
end
