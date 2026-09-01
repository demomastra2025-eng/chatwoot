class Conversations::AssignmentService
  UNSET = Object.new.freeze

  # rubocop:disable Metrics/ParameterLists
  def initialize(conversation:, assignee_id: UNSET, assignee_type: nil, team_id: UNSET, actor: Current.user, source: 'conversation_assignment')
    @conversation = conversation
    @assignee_id = assignee_id
    @assignee_type = assignee_type
    @team_id = team_id
    @actor = actor
    @source = source
  end
  # rubocop:enable Metrics/ParameterLists

  def perform
    validate_assignee_type!

    conversation.contact.with_lock do
      if conversation.communication_thread.present?
        update_communication_thread!
      else
        update_without_communication_thread!
      end
    end

    assignee_requested? ? assignee : team
  end

  private

  attr_reader :conversation, :assignee_id, :assignee_type, :team_id, :actor, :source

  def update_communication_thread!
    thread = conversation.communication_thread
    CommunicationThreads::UpdateService.new(
      communication_thread: thread,
      params: routing_params,
      accessible_links: thread.communication_thread_conversations,
      actor: actor,
      source: source
    ).perform
  end

  def update_without_communication_thread!
    if assignee_requested?
      conversation.contact.update!(owner: assignee)
      Contacts::OwnerSyncService.new(contact: conversation.contact).perform
    end
    return unless team_requested?

    conversation.contact.conversations.find_each { |linked_conversation| linked_conversation.update!(team: team) }
  end

  def routing_params
    {}.tap do |result|
      result[:assignee_id] = assignee&.id if assignee_requested?
      result[:team_id] = team&.id if team_requested?
    end.with_indifferent_access
  end

  def assignee_requested?
    !assignee_id.equal?(UNSET)
  end

  def team_requested?
    !team_id.equal?(UNSET)
  end

  def assignee
    @assignee ||= conversation.account.users.find_by(id: assignee_id)
  end

  def team
    @team ||= conversation.account.teams.find_by(id: team_id)
  end

  def validate_assignee_type!
    return unless assignee_requested? || assignee_type.present?
    return if assignee_type.blank? || assignee_type == 'User'

    raise ArgumentError, 'assignee_type must be User'
  end
end
