class Crm::Tasks::CustomerRoutingResolver
  Result = Data.define(:assignee, :team, :deal)

  def self.call(account:, contact:, conversation:, task_type:)
    new(account: account, contact: contact, conversation: conversation, task_type: task_type).call
  end

  def initialize(account:, contact:, conversation:, task_type:)
    @account = account
    @contact = contact
    @conversation = conversation
    @task_type = task_type
  end

  def call
    route = candidate_assignees.filter_map { |assignee| eligible_route_for(assignee) }.first
    raise_unroutable! if route.blank?

    Result.new(
      assignee: route.fetch(:assignee),
      team: route.fetch(:team),
      deal: compatible_linked_deal(route.fetch(:team))
    )
  end

  private

  attr_reader :account, :contact, :conversation, :task_type

  def linked_deal
    @linked_deal ||= Crm::Deals::ContactScope.resolve(account: account, contact: contact)
                                             .find_by(originating_conversation_id: conversation.id)
  end

  def candidate_assignees
    [task_type.customer_task_assignee, contact.owner, linked_deal&.owner, conversation.assignee].compact.uniq
  end

  def compatible_linked_deal(team)
    linked_deal if linked_deal&.team_id == team.id
  end

  def eligible_route_for(assignee)
    return unless account.account_users.exists?(user_id: assignee.id)

    team = task_type.customer_task_team || sole_member_team_for(assignee)
    return if team.blank? || !TeamMember.exists?(team_id: team.id, user_id: assignee.id)

    { assignee: assignee, team: team }
  end

  def sole_member_team_for(assignee)
    teams = account.teams.joins(:team_members).where(team_members: { user_id: assignee.id }).limit(2).to_a
    teams.one? ? teams.first : nil
  end

  def raise_unroutable!
    raise Crm::Error.new(
      code: 'CUSTOMER_TASK_UNROUTABLE',
      message: 'No eligible employee is available for this customer task type',
      status: :unprocessable_content,
      details: { task_type_id: task_type.id }
    )
  end
end
