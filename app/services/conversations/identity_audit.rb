class Conversations::IdentityAudit
  DEFAULT_LIMIT = 100

  def initialize(account_id: nil, limit: DEFAULT_LIMIT)
    @account_id = account_id.presence
    @limit = Integer(limit)
  end

  def perform
    rows = conflict_rows.limit(limit + 1).to_a
    truncated = rows.length > limit
    rows = rows.first(limit)

    {
      generated_at: Time.current.iso8601,
      read_only: true,
      identity: 'account_id:inbox_id:contact_id:primary',
      account_id: account_id,
      limit: limit,
      truncated: truncated,
      conflict_groups: rows.map { |row| serialize_group(row) }
    }
  end

  private

  attr_reader :account_id, :limit

  def conflict_rows
    scope = Conversation.joins(:inbox).where.not(inboxes: { channel_type: 'Channel::Email' })
    scope = scope.where(account_id: account_id) if account_id.present?

    scope
      .select(:account_id, :inbox_id, :contact_id, Arel.sql('COUNT(*) AS conversations_count'))
      .group(:account_id, :inbox_id, :contact_id)
      .having('COUNT(*) > 1')
      .order(Arel.sql('COUNT(*) DESC'), :account_id, :inbox_id, :contact_id)
  end

  def serialize_group(row)
    conversations = Conversation.where(
      account_id: row.account_id,
      inbox_id: row.inbox_id,
      contact_id: row.contact_id
    ).reorder(Arel.sql('campaign_id IS NULL DESC'), Arel.sql('last_activity_at DESC NULLS LAST'), created_at: :desc, id: :desc).to_a
    conversation_ids = conversations.map(&:id)

    counts = dependency_counts(conversation_ids)
    canonical = conversations.first

    {
      account_id: row.account_id,
      inbox_id: row.inbox_id,
      contact_id: row.contact_id,
      conversations_count: row.conversations_count.to_i,
      canonical_candidate_id: canonical&.id,
      conversations: conversations.map { |conversation| serialize_conversation(conversation, counts) }
    }
  end

  def dependency_counts(conversation_ids)
    {
      messages: Message.where(conversation_id: conversation_ids).reorder(nil).group(:conversation_id).count,
      call_sessions: Telephony::CallSession.where(conversation_id: conversation_ids).reorder(nil).group(:conversation_id).count,
      thread_links: CommunicationThreadConversation.where(conversation_id: conversation_ids).reorder(nil).group(:conversation_id).count,
      deals: Crm::Deal.where(originating_conversation_id: conversation_ids).reorder(nil).group(:originating_conversation_id).count
    }
  end

  def serialize_conversation(conversation, counts)
    {
      id: conversation.id,
      contact_inbox_id: conversation.contact_inbox_id,
      identity_key: conversation.identity_key,
      status: conversation.status,
      created_at: conversation.created_at&.iso8601,
      last_activity_at: conversation.last_activity_at&.iso8601,
      messages_count: counts[:messages].fetch(conversation.id, 0),
      call_sessions_count: counts[:call_sessions].fetch(conversation.id, 0),
      communication_thread_links_count: counts[:thread_links].fetch(conversation.id, 0),
      originating_deals_count: counts[:deals].fetch(conversation.id, 0)
    }
  end
end
