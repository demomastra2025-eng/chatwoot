# frozen_string_literal: true

class CommunicationThreads::UpdateService # rubocop:disable Metrics/ClassLength
  def initialize(communication_thread:, params:, accessible_links:, actor: Current.user, source: 'communication_thread')
    @communication_thread = communication_thread
    @current_account = communication_thread.account
    @params = params.to_h.with_indifferent_access
    @accessible_links = accessible_links
    @accessible_links = accessible_links.includes(:conversation) if accessible_links.respond_to?(:includes)
    @actor = actor
    @source = source.to_s.presence || 'communication_thread'
    @communication_thread_event_id = SecureRandom.uuid
    @communication_thread_event_occurred_at = Time.current
  end

  def perform
    source_conversation = linked_links.first&.conversation
    updated_thread = CommunicationThread.transaction do
      validate_routing!
      lock_routing_scope!
      Conversations::StatusTransitionService.with_locked_conversations(communication_thread) do
        sync_contact_owner!
        sync_participants_for_routing!
        sync_linked_conversations!
        clear_participants_if_resolved!
        refresh_communication_thread!
        communication_thread.reload
      end
    end

    enqueue_realtime_update(updated_thread, source_conversation)
    updated_thread
  end

  private

  attr_reader :communication_thread, :current_account, :params, :accessible_links, :actor, :source,
              :communication_thread_event_id, :communication_thread_event_occurred_at

  def routing_change?
    params.key?(:team_id) || params.key?(:assignee_id)
  end

  def lock_routing_scope!
    communication_thread.contact.lock! if params.key?(:assignee_id)
    Team.lock_routing_targets!(account_id: current_account.id, team_ids: [effective_team&.id]) if routing_change?
    lock_contact_conversations! if params.key?(:assignee_id)
  end

  def lock_contact_conversations!
    Conversation.where(account_id: current_account.id, contact_id: communication_thread.contact_id).order(:id).lock.load
  end

  def sync_linked_conversations!
    linked_links.order(:conversation_id).each do |link|
      sync_conversation!(link.conversation)
    end
  end

  def sync_contact_owner!
    return unless params.key?(:assignee_id)

    contact = communication_thread.contact
    owner_changed = contact.owner_id != human_assignee&.id
    contact.skip_communication_thread_owner_projection = true
    contact.update!(owner: human_assignee)
    # A repeated owner command must still repair unlinked channels. An
    # unchanged Contact does not run its owner-change callback.
    unless owner_changed
      Contacts::OwnerSyncService.new(contact: contact, actor: actor, source: source,
                                     source_event_id: communication_thread_event_id,
                                     skip_thread_projection: true).perform
    end
  ensure
    contact.skip_communication_thread_owner_projection = false if contact
  end

  def linked_links
    @linked_links ||= communication_thread.communication_thread_conversations.includes(:conversation)
  end

  def sync_conversation!(conversation)
    conversation.skip_communication_thread_refresh = true
    conversation.skip_communication_thread_realtime = true
    conversation.communication_thread_event_id = communication_thread_event_id
    conversation.communication_thread_event_actor = actor
    conversation.communication_thread_event_source = source
    conversation.communication_thread_event_source_record = communication_thread
    conversation.communication_thread_event_occurred_at = communication_thread_event_occurred_at
    assign_priority!(conversation)
    assign_agent!(conversation)
    assign_team!(conversation)
    assign_custom_attributes!(conversation)
    if params.key?(:status)
      assign_status!(conversation)
    elsif conversation.changed?
      conversation.save!
    end
  end

  def assign_status!(conversation)
    return unless params.key?(:status)

    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: status_transition_params,
      actor: actor,
      source: source,
      aggregate: false,
      source_record: communication_thread,
      source_event_id: communication_thread_event_id,
      occurred_at: communication_thread_event_occurred_at
    ).perform
  end

  def assign_priority!(conversation)
    return unless params.key?(:priority)

    conversation.priority = params[:priority]
  end

  def assign_agent!(conversation)
    return unless params.key?(:assignee_id)

    conversation.assignee = human_assignee
  end

  def assign_team!(conversation)
    return unless params.key?(:team_id) || params.key?(:assignee_id)

    conversation.team = effective_team
  end

  def assign_custom_attributes!(conversation)
    return unless params.key?(:custom_attributes) || params.key?(:destroy_custom_attributes)

    custom_attributes = conversation.custom_attributes || {}
    if params.key?(:custom_attributes)
      custom_attributes = CustomAttributes::MutationService.merge(
        custom_attributes,
        params[:custom_attributes]
      )
    end
    if params.key?(:destroy_custom_attributes)
      custom_attributes = CustomAttributes::MutationService.destroy(
        custom_attributes,
        params[:destroy_custom_attributes]
      )
    end

    conversation.custom_attributes = custom_attributes
  end

  def human_assignee
    return if params[:assignee_id].blank?

    current_account.account_users.find_by(user_id: params[:assignee_id])&.user
  end

  def effective_team
    return owner_team if human_assignee.present?
    return communication_thread.team unless params.key?(:team_id)

    current_account.teams.find_by(id: params[:team_id])
  end

  def owner_team
    @owner_team ||= begin
      teams = Team.joins(:team_members)
                  .where(account_id: current_account.id, team_members: { user_id: human_assignee.id })
                  .order(:id)
                  .limit(2)
                  .to_a
      raise ArgumentError, 'communication thread assignee belongs to multiple teams' if teams.many?

      teams.first
    end
  end

  def validate_routing!
    return unless params.key?(:team_id) && communication_thread.assignee_id.present? && !params.key?(:assignee_id)
    return if params[:team_id].to_i == team_for_user_id(communication_thread.assignee_id)&.id

    raise ArgumentError, 'communication thread team must match its assignee team'
  end

  def team_for_user_id(user_id)
    Team.joins(:team_members)
        .where(account_id: current_account.id, team_members: { user_id: user_id })
        .order(:id)
        .first
  end

  def sync_participants_for_routing!
    return unless params.key?(:assignee_id) && human_assignee.present?

    if communication_thread.team_id.present? && communication_thread.team_id != owner_team&.id
      participation_service.retain!(user_ids: new_team_participant_ids, reason: 'cross_team_transfer')
    end
    return unless communication_thread.communication_thread_participants.exists?(user_id: human_assignee.id)

    participation_service.remove!(user_id: human_assignee.id, reason: 'promoted_to_owner')
  end

  def clear_participants_if_resolved!
    return unless params[:status].to_s == 'resolved'

    participation_service.clear!(reason: 'thread_resolved')
  end

  def participation_service
    @participation_service ||= CommunicationThreads::ParticipationService.new(
      communication_thread: communication_thread,
      actor: actor
    )
  end

  def new_team_participant_ids
    return [] if owner_team.blank?

    TeamMember.where(team_id: owner_team.id).pluck(:user_id)
  end

  def status_transition_params
    params.slice(:status, :status_reason, :snoozed_until)
  end

  def enqueue_realtime_update(updated_thread, source_conversation)
    return if source_conversation.blank?

    CommunicationThreads::RealtimeUpdateJob.perform_later(
      communication_thread_id: updated_thread.id,
      source_conversation_id: source_conversation.id,
      source_event: params.key?(:status) ? 'conversation.status_changed' : 'conversation.updated',
      performer_id: actor&.id
    )
  end

  def refresh_communication_thread!
    seed_conversation = linked_links.first&.conversation
    return unless seed_conversation

    # Resolver#lock! reloads its record. Use a separate instance so the saved
    # conversations retain saved_changes for their after_commit activity callbacks.
    resolver_conversation = current_account.conversations.find(seed_conversation.id)
    Conversations::CommunicationThreadResolver.new(
      conversation: resolver_conversation,
      actor: actor,
      source: source,
      source_record: communication_thread,
      source_event_id: communication_thread_event_id,
      occurred_at: communication_thread_event_occurred_at
    ).perform
  end
end
