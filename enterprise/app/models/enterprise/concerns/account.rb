module Enterprise::Concerns::Account
  extend ActiveSupport::Concern

  included do
    store_accessor :settings, :conversation_required_attributes
    store_accessor :settings, :captain_default_assistant_id
    validate :captain_default_assistant_is_eligible

    has_many :sla_policies, dependent: :destroy_async
    has_many :applied_slas, dependent: :destroy_async
    has_many :custom_roles, dependent: :destroy_async
    has_many :agent_capacity_policies, dependent: :destroy_async

    has_many :captain_assistants, dependent: :destroy_async, class_name: 'Captain::Assistant'
    has_many :captain_assistant_responses, dependent: :destroy_async, class_name: 'Captain::AssistantResponse'
    has_many :captain_documents, dependent: :destroy_async, class_name: 'Captain::Document'
    has_many :captain_skills, dependent: :destroy_async, class_name: 'Captain::Skill'
    has_many :captain_custom_tools, dependent: :destroy_async, class_name: 'Captain::CustomTool'
    has_many :captain_mcp_servers, dependent: :destroy_async, class_name: 'Captain::McpServer'

    has_many :copilot_threads, dependent: :destroy_async
    has_many :companies, dependent: :destroy_async
    has_many :telephony_provider_connections, dependent: :destroy_async, class_name: '::Telephony::ProviderConnection'
    has_many :telephony_number_bindings, dependent: :destroy_async, class_name: '::Telephony::NumberBinding'
    has_many :telephony_sip_profiles, dependent: :destroy_async, class_name: '::Telephony::SipProfile'
    has_many :telephony_agent_bindings, dependent: :destroy_async, class_name: '::Telephony::AgentBinding'
    has_many :telephony_call_sessions, dependent: :destroy_async, class_name: '::Telephony::CallSession'
    has_many :telephony_routing_policies, dependent: :destroy_async, class_name: '::Telephony::RoutingPolicy'
    has_many :telephony_provisioning_runs, dependent: :destroy_async, class_name: '::Telephony::ProvisioningRun'
    has_many :telephony_events, dependent: :destroy_async, class_name: '::Telephony::Event'
    has_many :voice_channels, dependent: :destroy_async, class_name: '::Channel::Voice'
    has_many :calls, dependent: :destroy_async

    has_one :saml_settings, dependent: :destroy_async, class_name: 'AccountSamlSettings'
  end

  def captain_default_assistant_is_eligible
    value = captain_default_assistant_id
    return if value.blank?

    valid_id = value.to_s.match?(/\A[1-9]\d*\z/) && captain_assistants.entry_eligible.exists?(id: value.to_i)
    errors.add(:captain_default_assistant_id, I18n.t('captain.channel_matrix.invalid_default')) unless valid_id
  end
end
