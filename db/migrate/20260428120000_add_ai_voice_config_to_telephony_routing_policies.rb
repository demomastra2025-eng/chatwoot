class AddAiVoiceConfigToTelephonyRoutingPolicies < ActiveRecord::Migration[7.1]
  def change
    add_column :telephony_routing_policies, :ai_deployment_mode, :string, null: false, default: 'fonoster_managed'
    add_column :telephony_routing_policies, :fonoster_ai_app_ref, :string
    add_column :telephony_routing_policies, :onelink_ai_app_ref, :string
    add_column :telephony_routing_policies, :fallback_ai_app_ref, :string
    add_reference :telephony_routing_policies, :captain_assistant, foreign_key: { to_table: :captain_assistants }
    add_column :telephony_routing_policies, :ai_voice_settings, :jsonb, null: false, default: {}

    add_index :telephony_routing_policies, [:account_id, :ai_deployment_mode], name: 'index_telephony_routing_policies_on_account_ai_deployment'
  end
end
