class CreateRemindersAndReminderGroups < ActiveRecord::Migration[7.0]
  def change
    create_table :reminder_groups do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :creator, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.text :description
      t.jsonb :entity_kinds, null: false, default: []
      t.jsonb :touches, null: false, default: []
      t.boolean :active, null: false, default: true
      t.datetime :archived_at

      t.timestamps
    end

    add_index :reminder_groups, [:account_id, :active, :created_at], name: 'idx_reminder_groups_on_account_active_created'

    create_table :reminders do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :creator, foreign_key: { to_table: :users }
      t.references :owner, foreign_key: { to_table: :users }
      t.references :conversation, foreign_key: true
      t.references :target_inbox, foreign_key: { to_table: :inboxes }
      t.references :target_contact, foreign_key: { to_table: :contacts }
      t.references :target_contact_inbox, foreign_key: { to_table: :contact_inboxes }
      t.references :target_conversation, foreign_key: { to_table: :conversations }
      t.references :reminder_group, foreign_key: true
      t.references :remindable, polymorphic: true, index: true
      t.integer :status, null: false, default: 0
      t.integer :action_type, null: false, default: 0
      t.integer :content_kind, null: false, default: 0
      t.integer :text_mode, null: false, default: 0
      t.integer :timing_mode, null: false, default: 0
      t.string :relative_anchor
      t.integer :relative_offset_seconds, null: false, default: 0
      t.datetime :scheduled_at
      t.string :timezone, null: false, default: 'UTC'
      t.text :body
      t.text :instructions
      t.jsonb :attachments, null: false, default: []
      t.jsonb :template_params, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.string :fingerprint
      t.boolean :auto_cancel_on_incoming, null: false, default: true
      t.integer :attempts_count, null: false, default: 0
      t.text :last_error
      t.datetime :processing_started_at
      t.datetime :completed_at
      t.datetime :cancelled_at

      t.timestamps
    end

    add_index :reminders, [:account_id, :status, :scheduled_at], name: 'idx_reminders_on_account_status_scheduled'
    add_index :reminders, [:account_id, :owner_id, :scheduled_at], name: 'idx_reminders_on_account_owner_scheduled'
    add_index :reminders, [:account_id, :fingerprint], name: 'idx_reminders_on_account_fingerprint'
  end
end
