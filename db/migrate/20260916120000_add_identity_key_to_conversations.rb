class AddIdentityKeyToConversations < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_conversations_on_account_inbox_contact_identity'.freeze

  def up
    add_column :conversations, :identity_key, :string unless column_exists?(:conversations, :identity_key)
    return if identity_index_valid?

    remove_index :conversations, name: INDEX_NAME, algorithm: :concurrently if identity_index_exists?
    add_index :conversations,
              [:account_id, :inbox_id, :contact_id, :identity_key],
              where: 'identity_key IS NOT NULL',
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    remove_index :conversations, name: INDEX_NAME, algorithm: :concurrently if identity_index_exists?
    remove_column :conversations, :identity_key if column_exists?(:conversations, :identity_key)
  end

  private

  def identity_index_valid?
    return false unless identity_index_exists?

    select_value(<<~SQL.squish) == true
      SELECT indisvalid
      FROM pg_index
      WHERE indexrelid = #{connection.quote(INDEX_NAME)}::regclass
    SQL
  end

  def identity_index_exists?
    connection.indexes(:conversations).any? { |index| index.name == INDEX_NAME }
  end
end
