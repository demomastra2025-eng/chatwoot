class CreateWhatsappFlows < ActiveRecord::Migration[7.1]
  def change
    create_table :whatsapp_flows do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :inbox, null: false, foreign_key: true
      t.string :provider_flow_id
      t.string :name, null: false
      t.string :title
      t.string :status, null: false, default: 'draft'
      t.string :category
      t.string :mode
      t.jsonb :flow_json, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :whatsapp_flows, %i[account_id inbox_id name], unique: true
    add_index :whatsapp_flows, %i[account_id inbox_id provider_flow_id],
              unique: true,
              where: 'provider_flow_id IS NOT NULL',
              name: 'idx_whatsapp_flows_on_inbox_provider_flow_id'

    create_table :whatsapp_flow_sessions do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :inbox, null: false, foreign_key: true
      t.references :whatsapp_flow, null: false, foreign_key: true
      t.references :conversation, foreign_key: true
      t.references :message, foreign_key: true
      t.references :response_message, foreign_key: { to_table: :messages }
      t.string :token
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.string :status, null: false, default: 'pending'
      t.jsonb :request_payload, null: false, default: {}
      t.jsonb :response_payload, null: false, default: {}
      t.jsonb :metadata, null: false, default: {}
      t.datetime :sent_at
      t.datetime :submitted_at
      t.datetime :expires_at
      t.timestamps
    end

    add_index :whatsapp_flow_sessions, :token_digest, unique: true
    add_index :whatsapp_flow_sessions, %i[account_id inbox_id status], name: 'idx_whatsapp_flow_sessions_on_account_inbox_status'
    add_index :whatsapp_flow_sessions, %i[conversation_id status], name: 'idx_whatsapp_flow_sessions_on_conversation_status'
  end
end
