# Agent Bots were removed from the application (the AgentBot model is gone). The tables agent_bots and
# agent_bot_inboxes and the column conversations.assignee_agent_bot_id stay for one more release and are dropped later.
#
# What can still point at the removed class: a polymorphic type string 'AgentBot' makes Rails raise a NameError the
# moment the association is loaded (a message list, an audit list, a token lookup). This migration clears every such
# reference, in SQL and in batches, so it does not depend on any model. Running it again changes nothing.
class ClearRemovedAgentBotReferences < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  BATCH_SIZE = 5000

  # table => [type column, id column] of a record that was written by an agent bot: the actor is forgotten
  NULLED_REFERENCES = {
    'messages' => %w[sender_type sender_id],
    'conversation_status_transitions' => %w[actor_type actor_id],
    'audits' => %w[user_type user_id]
  }.freeze

  # table => type column of rows that belong to an agent bot and are deleted
  DELETED_ROWS = {
    'access_tokens' => 'owner_type',
    'platform_app_permissibles' => 'permissible_type',
    'active_storage_attachments' => 'record_type'
  }.freeze

  def up
    NULLED_REFERENCES.each { |table, (type_column, id_column)| clear_actor(table, type_column, id_column) }
    DELETED_ROWS.each { |table, type_column| delete_rows(table, type_column) }
    clear_conversation_assignees
  end

  def down
    # The removed references cannot be restored.
  end

  private

  def clear_actor(table, type_column, id_column)
    loop do
      updated = connection.exec_update(<<~SQL.squish)
        UPDATE #{table}
        SET #{type_column} = NULL, #{id_column} = NULL
        WHERE id IN (SELECT id FROM #{table} WHERE #{type_column} = 'AgentBot' LIMIT #{BATCH_SIZE})
      SQL
      break if updated < BATCH_SIZE
    end
  end

  def delete_rows(table, type_column)
    execute "DELETE FROM #{table} WHERE #{type_column} = 'AgentBot'"
  end

  def clear_conversation_assignees
    loop do
      updated = connection.exec_update(<<~SQL.squish)
        UPDATE conversations
        SET assignee_agent_bot_id = NULL
        WHERE id IN (SELECT id FROM conversations WHERE assignee_agent_bot_id IS NOT NULL LIMIT #{BATCH_SIZE})
      SQL
      break if updated < BATCH_SIZE
    end
  end
end
