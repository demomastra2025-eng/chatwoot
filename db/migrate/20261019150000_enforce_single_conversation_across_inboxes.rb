# frozen_string_literal: true

class EnforceSingleConversationAcrossInboxes < ActiveRecord::Migration[7.1]
  def up
    change_column_default :inboxes, :lock_to_single_conversation, from: false, to: true
    execute('UPDATE inboxes SET lock_to_single_conversation = TRUE WHERE lock_to_single_conversation = FALSE')
  end

  def down
    change_column_default :inboxes, :lock_to_single_conversation, from: true, to: false
  end
end
