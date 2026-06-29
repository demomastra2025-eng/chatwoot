class CreateLeadFormsAndSubmissions < ActiveRecord::Migration[7.1]
  def change
    create_table :lead_forms do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :inbox, foreign_key: true, index: true
      t.string :name, null: false
      t.text :description
      t.string :source_kind, null: false
      t.string :status, null: false, default: 'active'
      t.string :external_ref
      t.string :public_token, null: false
      t.jsonb :field_schema, null: false, default: []
      t.jsonb :settings, null: false, default: {}
      t.timestamps
    end

    add_index :lead_forms, :public_token, unique: true
    add_index :lead_forms, [:account_id, :source_kind, :external_ref], unique: true, where: 'external_ref IS NOT NULL'
    add_index :lead_forms, [:account_id, :source_kind, :status]
    add_index :lead_forms, :settings, using: :gin

    create_table :lead_submissions do |t|
      t.references :account, null: false, foreign_key: true, index: true
      t.references :lead_form, null: false, foreign_key: true, index: true
      t.references :inbox, foreign_key: true, index: true
      t.references :contact, foreign_key: true, index: true
      t.references :contact_inbox, foreign_key: true, index: true
      t.references :conversation, foreign_key: true, index: true
      t.references :crm_deal, foreign_key: { to_table: :crm_deals }, index: true
      t.string :source_kind, null: false
      t.string :status, null: false, default: 'received'
      t.string :external_ref
      t.string :idempotency_key
      t.jsonb :field_values, null: false, default: {}
      t.jsonb :utm, null: false, default: {}
      t.jsonb :payload, null: false, default: {}
      t.jsonb :processing_errors, null: false, default: {}
      t.datetime :processed_at
      t.timestamps
    end

    add_index :lead_submissions, [:account_id, :lead_form_id, :external_ref], unique: true, where: 'external_ref IS NOT NULL'
    add_index :lead_submissions, [:account_id, :lead_form_id, :idempotency_key], unique: true, where: 'idempotency_key IS NOT NULL'
    add_index :lead_submissions, [:account_id, :source_kind, :created_at]
    add_index :lead_submissions, :field_values, using: :gin
    add_index :lead_submissions, :payload, using: :gin
  end
end
