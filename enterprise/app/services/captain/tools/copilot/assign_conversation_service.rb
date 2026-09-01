class Captain::Tools::Copilot::AssignConversationService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'assign_conversation'
  end

  description 'Assign a contact and its omnichannel conversation thread to an agent or team'
  param :conversation_id, type: :integer, desc: 'Conversation display ID', required: true
  param :assignee_id, type: :integer, desc: 'Optional user ID', required: false
  param :assignee_type, type: :string, desc: 'Optional assignee type: User', required: false
  param :team_id, type: :integer, desc: 'Optional team ID. Pass null/omit assignee fields to only update team.', required: false

  def execute(conversation_id:, assignee_id: nil, assignee_type: nil, team_id: nil)
    conversation = conversation_operations.assign_conversation(
      conversation_id: conversation_id,
      assignee_id: assignee_id,
      assignee_type: assignee_type,
      team_id: team_id
    )

    formatted_payload(action: 'assign_conversation', conversation: conversation_payload(conversation))
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    user_has_permission('conversation_manage') ||
      user_has_permission('conversation_unassigned_manage') ||
      user_has_permission('conversation_team_manage') ||
      user_has_permission('conversation_participating_manage')
  end

  private

  def conversation_payload(conversation)
    {
      id: conversation.id,
      display_id: conversation.display_id,
      assignee_id: conversation.assignee_id,
      assignee_name: conversation.assignee&.name,
      team_id: conversation.team_id,
      team_name: conversation.team&.name,
      updated_at: conversation.updated_at&.iso8601
    }
  end

  def conversation_operations
    Captain::Tools::Operations::ConversationOperations.new(
      assistant: assistant,
      conversation: current_conversation,
      actor: @user
    )
  end
end
