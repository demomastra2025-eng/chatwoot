class Contacts::OwnerSyncService
  # rubocop:disable Metrics/ParameterLists
  def initialize(contact:, actor: Current.executed_by || Current.user, source: 'contact_owner_sync', source_event_id: nil,
                 skip_thread_projection: false, defer_thread_fact: false, human_takeover: false)
    @contact = contact
    @actor = actor
    @source = source
    @source_event_id = source_event_id.presence || SecureRandom.uuid
    @occurred_at = Time.current
    @skip_thread_projection = skip_thread_projection
    @defer_thread_fact = defer_thread_fact
    @human_takeover = human_takeover
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    return if contact.blank? || contact.destroyed?

    ApplicationRecord.transaction do
      sync_assignment_client_ownership!
      # Direct Contact updates already own Contact. Lock routing Team, then all
      # contact Threads, before touching any Conversation row. Thread-first
      # status, resolver and handoff paths cannot otherwise share this order.
      Team.lock_routing_targets!(account_id: contact.account_id, team_ids: [owner_team_id]) if owner_id.present?
      sync_communication_threads!
      sync_conversations!
      sync_open_reminders!
      sync_appointment_reminders!
    end
  end

  private

  attr_reader :contact, :actor, :source, :source_event_id, :occurred_at

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
    # The Thread command handles linked channels itself, but still needs the
    # Contact callback to update channels awaiting backfill.
    conversations_for_owner_sync.find_each { |conversation| sync_conversation!(conversation) }
  end

  def conversations_for_owner_sync
    scope = conversations_requiring_owner_sync
    scope = contact.conversations.where(account_id: contact.account_id) if human_takeover?
    @skip_thread_projection ? scope.where.missing(:communication_thread_conversation) : scope
  end

  def sync_conversation!(conversation)
    activate_human_for_unlinked_conversation!(conversation) if unlinked_human_takeover?(conversation)
    conversation.communication_thread_event_id = source_event_id
    conversation.communication_thread_event_actor = actor
    conversation.communication_thread_event_source = source
    conversation.communication_thread_event_source_record = contact
    conversation.communication_thread_event_occurred_at = occurred_at
    conversation.skip_communication_thread_refresh = true
    conversation.assignee_id = owner_id
    conversation.team_id = owner_team_id if owner_id.present?
    conversation.save! if conversation.changed?
  ensure
    conversation.skip_communication_thread_refresh = false if conversation
  end

  def conversations_requiring_owner_sync
    scope = contact.conversations.where(account_id: contact.account_id)
    records_with_routing_mismatch(scope, :assignee_id)
  end

  def sync_communication_threads!
    return if @skip_thread_projection || @defer_thread_fact

    # Lock even an already-routed Thread: a human takeover still invalidates
    # the pending AI generation. Keep the same ID order as linked writers.
    CommunicationThread.where(account_id: contact.account_id, contact_id: contact.id).order(:id).lock.load.each do |thread|
      activate_human_for_thread!(thread) if human_takeover?
      sync_thread_routing!(thread) if thread_routing_mismatch?(thread)
    end
  end

  def sync_thread_routing!(thread)
    reconcile_thread_participants!(thread)
    attributes = { assignee_id: owner_id }
    attributes[:team_id] = owner_team_id if owner_id.present?
    CommunicationThreads::StateTransitionWriter.new(
      thread: thread,
      attributes: attributes,
      actor: actor,
      source: source,
      source_record: contact,
      source_event_id: source_event_id,
      occurred_at: occurred_at
    ).perform
  end

  def thread_routing_mismatch?(thread)
    thread.assignee_id != owner_id || (owner_id.present? && thread.team_id != owner_team_id)
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

  def human_takeover?
    @human_takeover && actor.is_a?(User) && owner_id.present? && captain_contact?
  end

  def unlinked_human_takeover?(conversation) = human_takeover? && conversation.communication_thread_conversation.blank?

  def captain_contact?
    return @captain_contact if defined?(@captain_contact)

    inbox_ids = contact.conversations.where(account_id: contact.account_id).select(:inbox_id)
    @captain_contact = CaptainInbox.exists?(inbox_id: inbox_ids)
  end

  def activate_human_for_thread!(thread)
    conversation_id = thread.communication_thread_conversations.minimum(:conversation_id)
    return unless conversation_id

    Captain::Conversation::ControlService.new(Conversation.find(conversation_id))
                                         .activate_human_after_contact_lock!(source: source, actor: actor)
  end

  def activate_human_for_unlinked_conversation!(conversation)
    Captain::Conversation::ControlService.new(conversation).activate_human_after_contact_lock!(source: source, actor: actor)
  end

  def sync_open_reminders!
    open_reminders_requiring_owner_sync.find_each do |reminder|
      reminder.with_lock do
        next unless reminder.editable? || (reminder.processing? && !reminder.delivery_materialized?)

        reminder.update!(owner_id: owner_id) if reminder.owner_id != owner_id
      end
    end
  end

  def sync_appointment_reminders!
    contact.scheduling_appointments.where(account_id: contact.account_id).find_each do |appointment|
      appointment.with_lock do
        next unless appointment.contact_id == contact.id

        service = Reminders::SyncRemindableService.new(remindable: appointment, allow_processing: true)
        appointment.reminders.where(status: %w[draft pending processing]).find_each { |reminder| service.perform_for(reminder, raise_errors: true) }
      end
    end
  end

  def contact_conversation_ids
    @contact_conversation_ids ||= contact.conversations.where(account_id: contact.account_id).select(:id)
  end

  def open_reminders_requiring_owner_sync
    scope = Reminder.where(status: %w[draft pending processing])
                    .where(account_id: contact.account_id)
                    .where('remindable_type IS NULL OR remindable_type NOT IN (?)', %w[Crm::Deal Crm::Task Scheduling::Appointment])
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
