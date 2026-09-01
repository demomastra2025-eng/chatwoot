class NormalizeInboxConversationPolicy < ActiveRecord::Migration[7.1]
  def up
    say 'Inbox conversation policy normalization is deferred until all app processes run the new code'
  end

  def down; end
end
