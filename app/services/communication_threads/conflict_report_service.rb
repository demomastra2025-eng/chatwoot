class CommunicationThreads::ConflictReportService
  SAMPLE_LIMIT = 100

  def initialize(account_id: nil)
    @account_id = account_id.presence
  end

  def perform
    {
      account_id: account_id,
      duplicate_contact_thread_groups: duplicate_contact_thread_groups,
      contact_thread_owner_mismatches: mismatch_summary(thread_owner_mismatches),
      contact_conversation_owner_mismatches: mismatch_summary(conversation_owner_mismatches),
      thread_projection_routing_mismatches: mismatch_summary(projection_routing_mismatches)
    }
  end

  private

  attr_reader :account_id

  def thread_scope
    scope = CommunicationThread.all
    account_id ? scope.where(account_id: account_id) : scope
  end

  def conversation_scope
    scope = Conversation.all
    account_id ? scope.where(account_id: account_id) : scope
  end

  def duplicate_contact_thread_groups
    groups = thread_scope
             .group(:account_id, :contact_id)
             .having('COUNT(*) > 1')
             .count
    {
      count: groups.size,
      sample: groups.first(SAMPLE_LIMIT).map do |(group_account_id, contact_id), thread_count|
        { account_id: group_account_id, contact_id: contact_id, thread_count: thread_count }
      end
    }
  end

  def thread_owner_mismatches
    thread_scope
      .joins(:contact)
      .where('communication_threads.assignee_id IS DISTINCT FROM contacts.owner_id')
      .select(:id, :account_id, :contact_id)
  end

  def conversation_owner_mismatches
    conversation_scope
      .joins(:contact)
      .where('conversations.assignee_id IS DISTINCT FROM contacts.owner_id')
      .select(:id, :account_id, :contact_id)
  end

  def projection_routing_mismatches
    conversation_scope
      .joins(communication_thread_conversation: :communication_thread)
      .where(<<~SQL.squish)
        conversations.assignee_id IS DISTINCT FROM communication_threads.assignee_id OR
        conversations.team_id IS DISTINCT FROM communication_threads.team_id OR
        conversations.status IS DISTINCT FROM communication_threads.status OR
        conversations.priority IS DISTINCT FROM communication_threads.priority
      SQL
      .select(:id, :account_id, :contact_id)
  end

  def mismatch_summary(scope)
    {
      count: scope.unscope(:select).count,
      sample: scope.limit(SAMPLE_LIMIT).map do |record|
        { id: record.id, account_id: record.account_id, contact_id: record.contact_id }
      end
    }
  end
end
