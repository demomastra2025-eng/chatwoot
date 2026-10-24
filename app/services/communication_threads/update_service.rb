# frozen_string_literal: true

# Writes the fields of a person (status, priority, assignee, team, custom attributes) to the conversations of the thread the
# actor can reach, then refreshes the thread, which holds the one status of the person (the most urgent status of its
# conversations, see Conversations::CommunicationThreadResolver).
#
# The status is not written to every conversation:
# - resolve resolves every conversation, as before;
# - open, pending and snooze touch only the conversations that are not resolved, so the old channels of a person (resolved
#   long ago) are not reopened or snoozed and their status events, automation rules and webhooks do not fire;
# - when every conversation is resolved, a request to open (or to move to pending or snooze) the person brings back ONE
#   conversation, the one a person is reached in (the latest activity, see CommunicationThreads::SingleOpenDialogPlanner).
class CommunicationThreads::UpdateService
  # Statuses that apply to the conversations that are not resolved. Any other status (resolved, or a blank one that toggles)
  # is written to every conversation.
  ACTIVE_STATUS_TARGETS = %w[open pending snoozed].freeze

  def initialize(communication_thread:, params:, accessible_links:, actor: Current.user, source: 'communication_thread')
    @communication_thread = communication_thread
    @current_account = communication_thread.account
    @params = params.to_h.with_indifferent_access
    @accessible_links = accessible_links.respond_to?(:includes) ? accessible_links.includes(:conversation) : accessible_links
    @actor = actor
    @source = source.to_s.presence || 'communication_thread'
  end

  def perform
    source_conversation = ordered_links.first&.conversation
    updated_thread = CommunicationThread.transaction do
      sync_accessible_conversations!
      refresh_communication_thread!
      communication_thread.reload
    end

    enqueue_realtime_update(updated_thread, source_conversation)
    updated_thread
  end

  private

  attr_reader :communication_thread, :current_account, :params, :accessible_links, :actor, :source

  def sync_accessible_conversations!
    ordered_links.each_with_index do |link, index|
      sync_conversation!(link.conversation, skip_activity: index.positive?)
    end
  end

  # The links in the order they are written. The conversation whose status changes goes first, so the one activity note of the
  # change ("agent X marked the dialog pending") lands in the conversation that really changed.
  def ordered_links
    @ordered_links ||= begin
      links = accessible_links.to_a.sort_by(&:id)
      links.partition { |link| status_target_ids.include?(link.conversation_id) }.flatten
    end
  end

  def sync_conversation!(conversation, skip_activity: false)
    conversation.skip_communication_thread_refresh = true
    conversation.skip_communication_thread_realtime = true
    conversation.skip_activity_messages = skip_activity
    conversation.communication_thread_event_id = communication_thread_event_id
    assign_priority!(conversation)
    assign_agent!(conversation)
    assign_team!(conversation)
    assign_custom_attributes!(conversation)
    if status_target_ids.include?(conversation.id)
      assign_status!(conversation)
    elsif conversation.changed?
      conversation.save!
    end
  end

  # Ids of the conversations that get the requested status; empty when the request carries no status.
  def status_target_ids
    @status_target_ids ||= params.key?(:status) ? status_target_conversations.map(&:id) : []
  end

  def status_target_conversations
    conversations = accessible_links.to_a.map(&:conversation)
    return conversations unless ACTIVE_STATUS_TARGETS.include?(params[:status].to_s)

    active = conversations.reject(&:resolved?)
    active.presence || Array(reopened_conversation(conversations))
  end

  # Every channel is resolved: the person comes back in one of them, not in all.
  def reopened_conversation(conversations)
    CommunicationThreads::SingleOpenDialogPlanner.new(thread: communication_thread, conversations: conversations).conversation_to_keep
  end

  def assign_status!(conversation)
    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: status_transition_params,
      actor: actor,
      source: source
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

    conversation.team = target_team
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

  def target_team
    return @target_team if defined?(@target_team)

    @target_team = params[:team_id].present? ? current_account.teams.find_by(id: params[:team_id]) : nil
  end

  def human_assignee
    return @human_assignee if defined?(@human_assignee)

    @human_assignee = if params[:assignee_id].blank?
                        nil
                      else
                        current_account.account_users.find_by(user_id: params[:assignee_id])&.user
                      end
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
    seed_conversation = ordered_links.first&.conversation
    return unless seed_conversation

    # Resolver#lock! reloads its record. Use a separate instance so the saved
    # conversations retain saved_changes for their after_commit activity callbacks.
    resolver_conversation = current_account.conversations.find(seed_conversation.id)
    Conversations::CommunicationThreadResolver.new(conversation: resolver_conversation).perform
  end
end
