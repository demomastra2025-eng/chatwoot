# frozen_string_literal: true

# One row per person in the lists of conversations (a label, a team, an inbox, a folder, mentions): the conversations of one
# communication thread belong to the same contact, so when the list holds more than one of them only the open one with the
# latest activity is kept (without an open one, the latest). The main list is built from threads and has one row per thread
# already; this brings the lists of conversations to the same rule.
#
# The choice is made inside the list as it is filtered: a person whose only conversation with the label is an old resolved
# one is still found in the label view, and the rows and the counts stay the same set. The text search of a list is left
# alone, a search must show every conversation that matches.
class Conversations::ThreadRowDeduplicator
  FEATURE_NAME = 'communication_threads'

  def self.apply(scope, account:)
    return scope unless account&.feature_enabled?(FEATURE_NAME)

    new(scope).perform
  end

  def initialize(scope)
    @scope = scope
  end

  def perform
    @scope.where("conversations.id IN (#{first_row_per_thread_sql})")
  end

  private

  def first_row_per_thread_sql
    <<~SQL.squish
      SELECT ranked_rows.id
      FROM (
        SELECT thread_rows.id,
               ROW_NUMBER() OVER (
                 PARTITION BY COALESCE(thread_links.communication_thread_id, -thread_rows.id)
                 ORDER BY CASE WHEN thread_rows.status IN (#{open_status_values}) THEN 0 ELSE 1 END,
                          thread_rows.last_activity_at DESC, thread_rows.id DESC
               ) AS row_in_thread
        FROM conversations thread_rows
        LEFT JOIN communication_thread_conversations thread_links
               ON thread_links.conversation_id = thread_rows.id AND thread_links.account_id = thread_rows.account_id
        WHERE thread_rows.id IN (#{listed_ids_sql})
      ) ranked_rows
      WHERE ranked_rows.row_in_thread = 1
    SQL
  end

  def listed_ids_sql
    @scope.except(:includes, :preload, :eager_load, :order, :limit, :offset).reselect('conversations.id').to_sql
  end

  def open_status_values
    Conversation.statuses.values_at('open', 'pending').join(', ')
  end
end
