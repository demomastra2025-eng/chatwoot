class Conversations::AssignmentService
  # assignee_type is accepted for API compatibility; staff members (User) are the only assignees.
  def initialize(conversation:, assignee_id:, assignee_type: nil)
    @conversation = conversation
    @assignee_id = assignee_id
    @assignee_type = assignee_type
  end

  def perform
    conversation.assignee = assignee
    conversation.save!
    assignee
  end

  private

  attr_reader :conversation, :assignee_id, :assignee_type

  def assignee
    @assignee ||= conversation.account.users.find_by(id: assignee_id)
  end
end
