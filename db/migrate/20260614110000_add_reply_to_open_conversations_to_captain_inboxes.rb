class AddReplyToOpenConversationsToCaptainInboxes < ActiveRecord::Migration[7.0]
  def up
    add_column :captain_inboxes, :reply_to_open_conversations, :boolean, null: false, default: false

    # `never` used to mean "Captain is connected but silent". The product now represents
    # that state as "Captain disabled for the channel", so legacy rows are removed. Keep
    # voice routing in sync explicitly because raw migration SQL does not run model callbacks.
    execute <<~SQL.squish
      UPDATE telephony_routing_policies policies
      SET captain_assistant_id = NULL,
          ai_enabled = FALSE,
          updated_at = CURRENT_TIMESTAMP
      FROM telephony_number_bindings bindings
      INNER JOIN captain_inboxes captain_links
        ON captain_links.inbox_id = bindings.inbox_id
      WHERE policies.number_binding_id = bindings.id
        AND captain_links.auto_reply_mode = 'never'
        AND policies.captain_assistant_id = captain_links.captain_assistant_id
    SQL

    execute <<~SQL.squish
      DELETE FROM captain_inboxes WHERE auto_reply_mode = 'never'
    SQL
  end

  def down
    remove_column :captain_inboxes, :reply_to_open_conversations
  end
end
