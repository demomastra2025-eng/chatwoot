class FixTelephonyAgentBindingUserIndex < ActiveRecord::Migration[7.0]
  def change
    remove_index :telephony_agent_bindings, :user_id
    add_index :telephony_agent_bindings, [:account_id, :user_id], unique: true, name: 'index_telephony_agent_bindings_on_account_user'
  end
end
