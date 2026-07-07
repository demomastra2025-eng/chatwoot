class RetireFonosterTelephonyDefaults < ActiveRecord::Migration[7.1]
  def change
    change_column_default :telephony_agent_bindings, :provider, from: 'fonoster', to: nil
    change_column_default :telephony_call_sessions, :provider, from: 'fonoster', to: nil
    change_column_default :telephony_contact_endpoints, :provider, from: 'fonoster', to: nil
    change_column_default :telephony_number_bindings, :provider, from: 'fonoster', to: nil
    change_column_default :telephony_routing_policies, :ai_deployment_mode, from: 'fonoster_managed', to: 'onelink_managed'
  end
end
