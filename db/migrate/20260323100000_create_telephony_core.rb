class CreateTelephonyCore < ActiveRecord::Migration[7.0]
  def change
    create_telephony_number_bindings
    create_telephony_agent_bindings
    create_telephony_routing_policies
    create_telephony_call_sessions
    create_telephony_events
  end

  private

  def create_telephony_number_bindings
    create_table :telephony_number_bindings do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true, index: false
      t.string :provider, null: false, default: 'fonoster'
      t.string :number_ref, null: false
      t.string :phone_number
      t.string :app_ref
      t.string :trunk_ref
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :telephony_number_bindings, :inbox_id, unique: true
    add_index :telephony_number_bindings, [:account_id, :number_ref], unique: true, name: 'index_telephony_number_bindings_on_account_number_ref'
    add_index :telephony_number_bindings, [:account_id, :phone_number], name: 'index_telephony_number_bindings_on_account_phone'
  end

  def create_telephony_agent_bindings
    create_table :telephony_agent_bindings do |t|
      t.references :account, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true, index: false
      t.string :provider, null: false, default: 'fonoster'
      t.string :agent_ref, null: false
      t.string :agent_aor
      t.string :domain_ref
      t.string :credentials_ref
      t.boolean :enabled, null: false, default: true
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :telephony_agent_bindings, :user_id, unique: true
    add_index :telephony_agent_bindings, [:account_id, :agent_ref], unique: true, name: 'index_telephony_agent_bindings_on_account_agent_ref'
  end

  def create_telephony_routing_policies
    create_table :telephony_routing_policies do |t|
      t.references :account, null: false, foreign_key: true
      t.references :number_binding, null: false, foreign_key: { to_table: :telephony_number_bindings }, index: false
      t.string :mode, null: false, default: 'operator'
      t.boolean :ai_enabled, null: false, default: false
      t.string :ai_app_ref
      t.string :operator_agent_ref
      t.string :operator_agent_aor
      t.string :fallback_mode, null: false, default: 'reject'
      t.text :fallback_message
      t.jsonb :business_hours, null: false, default: {}
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :telephony_routing_policies, :number_binding_id, unique: true
    add_index :telephony_routing_policies, [:account_id, :mode], name: 'index_telephony_routing_policies_on_account_mode'
  end

  def create_telephony_call_sessions
    create_table :telephony_call_sessions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, foreign_key: true
      t.references :contact, foreign_key: true
      t.references :inbox, foreign_key: true
      t.references :number_binding, foreign_key: { to_table: :telephony_number_bindings }
      t.references :agent_binding, foreign_key: { to_table: :telephony_agent_bindings }
      t.string :provider, null: false, default: 'fonoster'
      t.string :external_call_ref, null: false
      t.string :provider_call_sid
      t.string :status, null: false, default: 'ringing'
      t.string :direction, null: false, default: 'outbound'
      t.string :from_number
      t.string :to_number
      t.string :recording_ref
      t.string :transcript_ref
      t.text :summary
      t.integer :duration_seconds
      t.datetime :started_at
      t.datetime :ended_at
      t.datetime :last_event_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :telephony_call_sessions, [:account_id, :external_call_ref], unique: true, name: 'index_telephony_call_sessions_on_account_call_ref'
    add_index :telephony_call_sessions,
              [:account_id, :provider_call_sid],
              unique: true,
              where: 'provider_call_sid IS NOT NULL',
              name: 'index_telephony_call_sessions_on_account_provider_sid'
    add_index :telephony_call_sessions, [:account_id, :conversation_id], name: 'index_telephony_call_sessions_on_account_conversation'
    add_index :telephony_call_sessions, [:account_id, :status, :direction], name: 'index_telephony_call_sessions_on_account_status_direction'
    add_index :telephony_call_sessions, [:account_id, :created_at], name: 'index_telephony_call_sessions_on_account_created_at'
  end

  def create_telephony_events
    create_table :telephony_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :call_session, foreign_key: { to_table: :telephony_call_sessions }
      t.string :event_key, null: false
      t.string :event_type, null: false
      t.string :status, null: false, default: 'received'
      t.jsonb :payload, null: false, default: {}
      t.datetime :processed_at
      t.text :error_message

      t.timestamps
    end

    add_index :telephony_events, [:account_id, :event_key], unique: true, name: 'index_telephony_events_on_account_event_key'
    add_index :telephony_events, [:account_id, :event_type, :created_at], name: 'index_telephony_events_on_account_event_type_created_at'
  end
end
