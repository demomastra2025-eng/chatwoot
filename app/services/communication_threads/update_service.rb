# frozen_string_literal: true

class CommunicationThreads::UpdateService
  def initialize(communication_thread:, params:, accessible_links:, actor: Current.user, source: 'communication_thread')
    @communication_thread = communication_thread
    @current_account = communication_thread.account
    @params = params.to_h.with_indifferent_access
    @accessible_links = accessible_links
    @accessible_links = accessible_links.includes(:conversation) if accessible_links.respond_to?(:includes)
    @actor = actor
    @source = source.to_s.presence || 'communication_thread'
  end

  def perform
    source_conversation = linked_links.first&.conversation
    updated_thread = CommunicationThread.transaction do
      sync_contact_owner!
      sync_linked_conversations!
      refresh_communication_thread!
      communication_thread.reload
    end

    enqueue_realtime_update(updated_thread, source_conversation)
    updated_thread
  end

  private

  attr_reader :communication_thread, :current_account, :params, :accessible_links, :actor, :source

  def sync_linked_conversations!
    linked_links.each do |link|
      sync_conversation!(link.conversation)
    end
  end

  def sync_contact_owner!
    return unless params.key?(:assignee_id)

    communication_thread.contact.update!(owner: human_assignee)
  end

  def linked_links
    @linked_links ||= communication_thread.communication_thread_conversations.includes(:conversation)
  end

  def sync_conversation!(conversation)
    conversation.skip_communication_thread_refresh = true
    conversation.skip_communication_thread_realtime = true
    conversation.communication_thread_event_id = communication_thread_event_id
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
      aggregate: false
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
    return unless params.key?(:team_id)

    conversation.team = current_account.teams.find_by(id: params[:team_id])
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

  def status_transition_params
    params.slice(:status, :status_reason, :snoozed_until)
  end

  def communication_thread_event_id
    @communication_thread_event_id ||= SecureRandom.uuid
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
    Conversations::CommunicationThreadResolver.new(conversation: resolver_conversation).perform
  end
end
