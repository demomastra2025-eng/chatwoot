class CommunicationThreads::UnreadStatusCountService
  STATUS_KEYS = %w[open pending snoozed resolved].freeze

  def initialize(account:, thread_scope:, conversation_scope:)
    @account = account
    @thread_scope = thread_scope
    @conversation_scope = conversation_scope
  end

  def perform
    counts_by_status = connection.select_rows(query).to_h { |status, count| [status.to_i, count.to_i] }

    STATUS_KEYS.index_with do |status|
      counts_by_status.fetch(CommunicationThread.statuses.fetch(status), 0)
    end
  end

  private

  attr_reader :account, :thread_scope, :conversation_scope

  def connection
    ActiveRecord::Base.connection
  end

  def query
    <<~SQL.squish
      WITH unread_threads AS MATERIALIZED (#{unread_threads_sql}),
      thread_status_memberships AS (#{status_memberships_sql})
      SELECT status, COUNT(*)
      FROM thread_status_memberships
      GROUP BY status
    SQL
  end

  def unread_threads_sql
    thread_scope
      .except(:order)
      .reselect('communication_threads.id', 'communication_threads.status')
      .distinct
      .to_sql
  end

  def accessible_conversations_sql
    conversation_scope
      .reselect('conversations.id', 'conversations.account_id', 'conversations.status')
      .to_sql
  end

  def status_memberships_sql
    <<~SQL.squish
      SELECT unread_threads.id, unread_threads.status
      FROM unread_threads
      UNION
      SELECT unread_threads.id, status_conversations.status
      FROM unread_threads
      INNER JOIN communication_thread_conversations status_links
        ON status_links.communication_thread_id = unread_threads.id
       AND status_links.account_id = #{account.id.to_i}
      INNER JOIN (#{accessible_conversations_sql}) status_conversations
        ON status_conversations.id = status_links.conversation_id
       AND status_conversations.account_id = status_links.account_id
    SQL
  end
end
