class Contacts::OwnerSyncService
  def initialize(contact:)
    @contact = contact
  end

  def perform
    return if contact.blank? || contact.destroyed?

    ApplicationRecord.transaction do
      sync_assignment_client_ownership!
      sync_conversations!
      sync_communication_threads!
      sync_scheduling_appointments!
      sync_open_reminders!
    end
  end

  private

  attr_reader :contact

  def owner_id
    contact.owner_id
  end

  def sync_assignment_client_ownership!
    scope = AssignmentClientOwnership.where(account_id: contact.account_id, contact_id: contact.id)

    if owner_id.blank?
      scope.destroy_all
      return
    end

    scope.where.not(user_id: owner_id).find_each do |ownership|
      ownership.update!(user_id: owner_id, last_assigned_at: Time.current)
    end
  end

  def sync_conversations!
    conversations_requiring_owner_sync.find_each do |conversation|
      conversation.assignee_id = owner_id
      conversation.team_id = owner_team_id if owner_id.present?
      conversation.save! if conversation.changed?
    end
  end

  def conversations_requiring_owner_sync
    scope = contact.conversations.where(account_id: contact.account_id)
    records_with_routing_mismatch(scope, :assignee_id)
  end

  def sync_communication_threads!
    threads_requiring_owner_sync.find_each do |thread|
      reconcile_thread_participants!(thread)
      attributes = { assignee_id: owner_id }
      attributes[:team_id] = owner_team_id if owner_id.present?
      thread.update!(attributes)
    end
  end

  def reconcile_thread_participants!(thread)
    return if owner_id.blank?

    participation_service = CommunicationThreads::ParticipationService.new(
      communication_thread: thread,
      actor: Current.executed_by || Current.user
    )
    if thread.team_id.present? && thread.team_id != owner_team_id
      participation_service.retain!(user_ids: owner_team_user_ids, reason: 'cross_team_transfer')
    end
    return unless thread.communication_thread_participants.exists?(user_id: owner_id)

    participation_service.remove!(user_id: owner_id, reason: 'promoted_to_owner')
  end

  def threads_requiring_owner_sync
    scope = CommunicationThread.where(account_id: contact.account_id, contact_id: contact.id)
    records_with_routing_mismatch(scope, :assignee_id)
  end

  def sync_scheduling_appointments!
    scheduling_appointments_requiring_owner_sync.find_each do |appointment|
      appointment.update!(owner_id: owner_id)
    end
  end

  def scheduling_appointments_requiring_owner_sync
    scope = contact.scheduling_appointments.where(account_id: contact.account_id)
    records_with_owner_mismatch(scope, :owner_id)
  end

  def sync_open_reminders!
    open_reminders_requiring_owner_sync.find_each do |reminder|
      reminder.update!(owner_id: owner_id)
    end
  end

  def contact_conversation_ids
    @contact_conversation_ids ||= contact.conversations.where(account_id: contact.account_id).select(:id)
  end

  def open_reminders_requiring_owner_sync
    scope = Reminder.open_statuses
                    .where(account_id: contact.account_id)
                    .where('remindable_type IS NULL OR remindable_type NOT IN (?)', %w[Crm::Deal Crm::Task])
    contact_reminders = scope.where(target_contact_id: contact.id)
    target_conversation_reminders = scope.where(target_conversation_id: contact_conversation_ids)
    conversation_reminders = scope.where(conversation_id: contact_conversation_ids)

    records_with_owner_mismatch(
      contact_reminders.or(target_conversation_reminders).or(conversation_reminders),
      :owner_id
    )
  end

  def records_with_owner_mismatch(scope, column)
    return scope.where.not(column => nil) if owner_id.blank?

    scope.where(column => nil).or(scope.where.not(column => owner_id))
  end

  def records_with_routing_mismatch(scope, owner_column)
    owner_mismatch = records_with_owner_mismatch(scope, owner_column)
    return owner_mismatch if owner_id.blank?

    owner_mismatch.or(scope.where.not(team_id: owner_team_id)).or(scope.where(team_id: nil))
  end

  def owner_team_id
    return @owner_team_id if defined?(@owner_team_id)
    return @owner_team_id = nil if owner_id.blank?

    team_ids = TeamMember.joins(:team)
                         .where(user_id: owner_id, teams: { account_id: contact.account_id })
                         .order(:team_id)
                         .limit(2)
                         .pluck(:team_id)
    raise ArgumentError, 'contact owner belongs to multiple teams' if team_ids.many?

    @owner_team_id = team_ids.first
  end

  def owner_team_user_ids
    return [] if owner_team_id.blank?

    TeamMember.where(team_id: owner_team_id).pluck(:user_id)
  end
end
