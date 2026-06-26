# frozen_string_literal: true

class CommunicationThreads::UpdateService
  def initialize(communication_thread:, params:, accessible_links:, actor: Current.user, source: 'communication_thread')
    @communication_thread = communication_thread
    @current_account = communication_thread.account
    @params = params.to_h.with_indifferent_access
    @accessible_links = accessible_links.includes(:conversation)
    @actor = actor
    @source = source.to_s.presence || 'communication_thread'
  end

  def perform
    CommunicationThread.transaction do
      sync_accessible_conversations!
      refresh_communication_thread!
      communication_thread.reload
    end
  end

  private

  attr_reader :communication_thread, :current_account, :params, :accessible_links, :actor, :source

  def sync_accessible_conversations!
    accessible_links.each do |link|
      sync_conversation!(link.conversation)
    end
  end

  def sync_conversation!(conversation)
    assign_status!(conversation)
    assign_priority!(conversation)
    assign_agent!(conversation)
    assign_team!(conversation)
    conversation.save! if conversation.changed?
  end

  def assign_status!(conversation)
    return unless params.key?(:status)

    Conversations::StatusTransitionService.new(
      conversation: conversation,
      params: status_transition_params,
      actor: actor,
      source: source
    ).perform
    conversation.reload
  end

  def assign_priority!(conversation)
    return unless params.key?(:priority)

    conversation.priority = params[:priority]
  end

  def assign_agent!(conversation)
    return unless params.key?(:assignee_id)

    if agent_bot_assignment?
      Conversations::AssignmentService.new(
        conversation: conversation,
        assignee_id: params[:assignee_id],
        assignee_type: params[:assignee_type]
      ).perform
      conversation.reload
      return
    end

    conversation.assignee = human_assignee
    conversation.assignee_agent_bot = nil
  end

  def assign_team!(conversation)
    return unless params.key?(:team_id)

    conversation.team = current_account.teams.find_by(id: params[:team_id])
  end

  def human_assignee
    return if params[:assignee_id].blank?

    current_account.account_users.find_by(user_id: params[:assignee_id])&.user
  end

  def agent_bot_assignment?
    params[:assignee_type].to_s == 'AgentBot'
  end

  def status_transition_params
    params.slice(:status, :status_reason, :snoozed_until)
  end

  def refresh_communication_thread!
    seed_conversation = accessible_links.first&.conversation
    return unless seed_conversation

    Conversations::CommunicationThreadResolver.new(conversation: seed_conversation).perform
  end
end
