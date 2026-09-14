class CreateCommunicationThreadParticipants < ActiveRecord::Migration[7.1]
  def up
    create_participants_table
    add_participant_indexes
    add_participant_tenant_foreign_keys
  end

  def down
    drop_table :communication_thread_participants
  end

  private

  def create_participants_table
    create_table :communication_thread_participants do |t|
      t.references :account, null: false, foreign_key: true
      t.references :communication_thread, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true
      t.references :added_by, null: true, foreign_key: { to_table: :users }
      t.timestamps
    end
  end

  def add_participant_indexes
    add_index :communication_thread_participants,
              [:communication_thread_id, :user_id],
              unique: true,
              name: 'idx_thread_participants_thread_user'
    add_index :communication_thread_participants,
              [:account_id, :user_id, :communication_thread_id],
              name: 'idx_thread_participants_account_user_thread'
  end

  def add_participant_tenant_foreign_keys
    add_foreign_key :communication_thread_participants,
                    :communication_threads,
                    column: [:account_id, :communication_thread_id],
                    primary_key: [:account_id, :id],
                    name: 'fk_thread_participants_thread_account'
    add_foreign_key :communication_thread_participants,
                    :account_users,
                    column: [:account_id, :user_id],
                    primary_key: [:account_id, :user_id],
                    name: 'fk_thread_participants_user_account'
    add_foreign_key :communication_thread_participants,
                    :account_users,
                    column: [:account_id, :added_by_id],
                    primary_key: [:account_id, :user_id],
                    name: 'fk_thread_participants_added_by_account'
  end
end
