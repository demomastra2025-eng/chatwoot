class CreateCrmRuntimeTables < ActiveRecord::Migration[7.0]
  def change
    create_crm_deals_table
    create_crm_deal_contacts_table
    create_crm_tasks_table
    create_crm_events_table
  end

  private

  def create_crm_deals_table
    create_table :crm_deals do |t|
      t.references :account, null: false, foreign_key: true
      t.references :pipeline, null: false, foreign_key: { to_table: :crm_pipelines }
      t.references :stage, null: false, foreign_key: { to_table: :crm_stages }
      t.references :owner, foreign_key: { to_table: :users }
      t.references :creator, foreign_key: { to_table: :users }
      t.references :team, foreign_key: true
      t.references :company, foreign_key: true
      t.references :originating_conversation, foreign_key: { to_table: :conversations }
      t.string :title, null: false
      t.text :description
      t.bigint :amount_minor
      t.string :currency
      t.date :expected_close_on
      t.datetime :closed_at
      t.integer :win_probability
      t.string :external_ref
      t.string :idempotency_key
      t.integer :lock_version, null: false, default: 0
      t.jsonb :custom_attributes, null: false, default: {}
      t.datetime :archived_at

      t.timestamps
    end

    add_index :crm_deals,
              [:account_id, :external_ref],
              unique: true,
              where: 'external_ref IS NOT NULL',
              name: 'index_crm_deals_on_account_external_ref'
    add_index :crm_deals,
              [:account_id, :idempotency_key],
              unique: true,
              where: 'idempotency_key IS NOT NULL',
              name: 'index_crm_deals_on_account_idempotency_key'
    add_index :crm_deals,
              [:account_id, :pipeline_id, :stage_id, :owner_id, :expected_close_on],
              where: 'archived_at IS NULL',
              name: 'index_crm_deals_on_active_list_dimensions'
    add_index :crm_deals, [:account_id, :company_id], name: 'index_crm_deals_on_account_company'
    add_index :crm_deals, [:account_id, :team_id], name: 'index_crm_deals_on_account_team'
    add_index :crm_deals,
              [:account_id, :originating_conversation_id],
              name: 'index_crm_deals_on_account_originating_conversation'
    add_index :crm_deals, :custom_attributes, using: :gin, name: 'index_crm_deals_on_custom_attributes'
  end

  def create_crm_deal_contacts_table
    create_table :crm_deal_contacts do |t|
      t.references :account, null: false, foreign_key: true
      t.references :deal, null: false, foreign_key: { to_table: :crm_deals }
      t.references :contact, null: false, foreign_key: true
      t.boolean :primary, null: false, default: false

      t.timestamps
    end

    add_index :crm_deal_contacts, [:deal_id, :contact_id], unique: true, name: 'index_crm_deal_contacts_on_deal_contact'
    add_index :crm_deal_contacts,
              :deal_id,
              unique: true,
              where: '"primary" = true',
              name: 'index_crm_deal_contacts_on_primary_contact'
    add_index :crm_deal_contacts, [:account_id, :contact_id], name: 'index_crm_deal_contacts_on_account_contact'
  end

  def create_crm_tasks_table
    create_table :crm_tasks do |t|
      t.references :account, null: false, foreign_key: true
      t.references :deal, foreign_key: { to_table: :crm_deals }
      t.references :status, null: false, foreign_key: { to_table: :crm_task_statuses }
      t.references :assignee, foreign_key: { to_table: :users }
      t.references :creator, foreign_key: { to_table: :users }
      t.references :team, foreign_key: true
      t.string :title, null: false
      t.text :description
      t.string :priority, null: false, default: 'medium'
      t.datetime :start_at
      t.datetime :due_at
      t.datetime :completed_at
      t.string :external_ref
      t.string :idempotency_key
      t.integer :lock_version, null: false, default: 0
      t.jsonb :custom_attributes, null: false, default: {}
      t.datetime :archived_at

      t.timestamps
    end

    add_index :crm_tasks,
              [:account_id, :external_ref],
              unique: true,
              where: 'external_ref IS NOT NULL',
              name: 'index_crm_tasks_on_account_external_ref'
    add_index :crm_tasks,
              [:account_id, :idempotency_key],
              unique: true,
              where: 'idempotency_key IS NOT NULL',
              name: 'index_crm_tasks_on_account_idempotency_key'
    add_index :crm_tasks,
              [:account_id, :status_id, :assignee_id, :due_at],
              where: 'archived_at IS NULL',
              name: 'index_crm_tasks_on_active_list_dimensions'
    add_index :crm_tasks, [:account_id, :deal_id], name: 'index_crm_tasks_on_account_deal'
    add_index :crm_tasks, [:account_id, :team_id], name: 'index_crm_tasks_on_account_team'
    add_index :crm_tasks, :custom_attributes, using: :gin, name: 'index_crm_tasks_on_custom_attributes'
  end

  def create_crm_events_table
    create_table :crm_events do |t|
      t.references :account, null: false, foreign_key: true
      t.string :eventable_type, null: false
      t.bigint :eventable_id, null: false
      t.references :actor, foreign_key: { to_table: :users }
      t.string :event_type, null: false
      t.jsonb :meta, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :crm_events,
              [:account_id, :eventable_type, :eventable_id, :created_at],
              name: 'index_crm_events_on_account_eventable_created_at'
  end
end
