# frozen_string_literal: true

class ExpandAssignmentPoliciesForLoadEngine < ActiveRecord::Migration[7.1]
  def change
    expand_assignment_policies
    create_assignment_client_ownerships
    create_assignment_quota_usages
    create_assignment_decision_logs
  end

  private

  def expand_assignment_policies
    change_table :assignment_policies, bulk: true do |t|
      t.integer :assignment_delay_minutes, null: false, default: 0
      t.integer :max_open_conversations
      t.integer :monthly_new_client_quota
      t.boolean :sticky_owner_enabled, null: false, default: false
      t.integer :sticky_owner_duration_days, null: false, default: 30
    end
  end

  def create_assignment_client_ownerships
    create_table :assignment_client_ownerships do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :contact, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true
      t.references :assignment_policy,
                   foreign_key: { on_delete: :nullify },
                   index: { name: 'index_assignment_ownerships_on_policy_id' }
      t.datetime :last_assigned_at, null: false
      t.datetime :expires_at
      t.timestamps
    end

    add_index :assignment_client_ownerships, [:account_id, :contact_id], unique: true, name: 'idx_assignment_ownerships_account_contact'
    add_index :assignment_client_ownerships, [:account_id, :user_id], name: 'idx_assignment_ownerships_account_user'
    add_index :assignment_client_ownerships, :expires_at
  end

  def create_assignment_quota_usages
    create_table :assignment_quota_usages do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true
      t.references :contact, null: false, foreign_key: true, index: true
      t.references :conversation, foreign_key: true, index: true
      t.references :assignment_policy,
                   foreign_key: { on_delete: :nullify },
                   index: { name: 'index_assignment_quota_usages_on_policy_id' }
      t.date :period_start, null: false
      t.date :period_end, null: false
      t.timestamps
    end

    add_index :assignment_quota_usages, [:account_id, :user_id, :period_start], name: 'idx_assignment_quota_usages_account_user_period'
    add_index :assignment_quota_usages,
              [:account_id, :user_id, :contact_id, :period_start],
              unique: true,
              name: 'idx_assignment_quota_usages_unique_contact_period'
  end

  def create_assignment_decision_logs
    create_table :assignment_decision_logs do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :inbox, null: false, foreign_key: true, index: true
      t.references :conversation, null: false, foreign_key: true, index: true
      t.references :assignment_policy,
                   foreign_key: { on_delete: :nullify },
                   index: { name: 'index_assignment_decision_logs_on_policy_id' }
      t.references :assigned_user, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
      t.integer :outcome, null: false, default: 0
      t.jsonb :reasons, null: false, default: []
      t.jsonb :candidate_summaries, null: false, default: []
      t.jsonb :decision_metadata, null: false, default: {}
      t.timestamps
    end

    add_index :assignment_decision_logs, [:account_id, :created_at], name: 'idx_assignment_decision_logs_account_created_at'
    add_index :assignment_decision_logs, [:conversation_id, :created_at], name: 'idx_assignment_decision_logs_conversation_created_at'
    add_index :assignment_decision_logs, [:inbox_id, :outcome, :created_at], name: 'idx_assignment_decision_logs_inbox_outcome_created_at'
  end
end
