class RetireFonosterTelephonyDefaults < ActiveRecord::Migration[7.1]
  def change
    change_column_default :telephony_agent_bindings, :provider, from: 'fonoster', to: nil
    change_column_default :telephony_call_sessions, :provider, from: 'fonoster', to: nil
    # This retired domain has no creation migration in the supported fresh chain.
    # Older installations may still have the table and must clear its default.
    change_column_default :telephony_contact_endpoints, :provider, from: 'fonoster', to: nil if table_exists?(:telephony_contact_endpoints)
    change_column_default :telephony_number_bindings, :provider, from: 'fonoster', to: nil
    change_column_default :telephony_routing_policies, :ai_deployment_mode, from: 'fonoster_managed', to: 'onelink_managed'
  end
end
