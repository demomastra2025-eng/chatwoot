class CommunicationThreads::ParticipationService
  def initialize(communication_thread:, actor: Current.user)
    @communication_thread = communication_thread
    @actor = actor
  end

  def add!(user_id:, reason: 'manual_add')
    participant_user = active_workspace_user!(user_id)
    raise ArgumentError, 'assignee cannot also be a participant' if communication_thread.assignee_id == participant_user.id

    created = false
    membership = CommunicationThreadParticipant.transaction do
      record = CommunicationThreadParticipant.find_or_create_for!(
        communication_thread: communication_thread,
        user_id: participant_user.id,
        added_by: actor,
        audit_comment: reason
      )
      if record.previously_new_record?
        create_activity!(:added, participant_user, reason)
        created = true
      end
      record
    end
    enqueue_realtime!(recipient_user_ids: [participant_user.id]) if created
    membership
  end

  def remove!(user_id:, reason: 'manual_remove')
    participant_user = nil
    membership = CommunicationThreadParticipant.transaction do
      record = communication_thread.communication_thread_participants.find_by!(user_id: user_id)
      participant_user = record.user
      destroy_membership!(record, participant_user, reason)
      record
    end
    enqueue_realtime!(recipient_user_ids: [participant_user.id])
    membership
  end

  def clear!(reason: 'participants_cleared')
    removed_user_ids = CommunicationThreadParticipant.transaction do
      communication_thread.communication_thread_participants.includes(:user).map do |membership|
        participant_user = membership.user
        destroy_membership!(membership, participant_user, reason)
        participant_user.id
      end
    end
    enqueue_realtime!(recipient_user_ids: removed_user_ids) if removed_user_ids.any?
  end

  def retain!(user_ids:, reason: 'participation_scope_changed')
    retained_ids = Array(user_ids).map(&:to_i)
    removed_user_ids = CommunicationThreadParticipant.transaction do
      communication_thread.communication_thread_participants.where.not(user_id: retained_ids).includes(:user).map do |membership|
        participant_user = membership.user
        destroy_membership!(membership, participant_user, reason)
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

  def destroy_membership!(membership, participant_user, reason)
    membership.audit_comment = reason
    membership.destroy!
    create_activity!(:removed, participant_user, reason)
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
