# frozen_string_literal: true

module Telephony::RoutingPolicy::PublicSettings
  extend ActiveSupport::Concern

  CALL_ROUTING_SCHEMA = {
    'show_extended_call_card' => :boolean,
    'inbound' => {
      **%w[routing_authority schedule_mode off_hours_action off_hours_forward_number ringtone
           fallback_action fallback_forward_number].index_with { :string },
      'ring_timeout_seconds' => :number, 'skip_busy_operators' => :boolean,
      'groups' => [{ **%w[id name strategy].index_with { :string }, 'ring_seconds' => :number, 'user_ids' => [:number] }],
      'whatsapp_followup' => {
        'enabled' => :boolean, 'inbox_id' => :scalar, 'cooldown_minutes' => :number,
        **%w[template_name template_language custom_message].index_with { :string }
      }
    },
    'outbound' => { 'access_mode' => :string, 'allowed_user_ids' => [:number], 'caller_id_number' => :string }
  }.freeze
  PUBLIC_SETTINGS_SCHEMA = {
    'operator_distribution_mode' => :string, 'last_non_ai_mode' => :string,
    'max_call_duration_seconds' => :scalar, 'call_routing' => CALL_ROUTING_SCHEMA
  }.freeze

  class_methods do
    def public_call_routing(value)
      PublicJsonFields.project(normalize_public_routing(value, CALL_ROUTING_SCHEMA), CALL_ROUTING_SCHEMA)
    end

    private

    def normalize_public_routing(value, schema)
      case schema
      when Hash
        normalize_public_routing_object(value, schema)
      when Array
        value.is_a?(Array) ? value.map { |child| normalize_public_routing(child, schema.first) } : value
      else
        normalize_public_routing_scalar(value, schema)
      end
    end

    def normalize_public_routing_object(value, schema)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, child), result|
        result[key.to_s] = normalize_public_routing(child, schema[key.to_s]) if schema.key?(key.to_s)
      end
    end

    def normalize_public_routing_scalar(value, schema)
      return value unless value.is_a?(String)
      return ActiveModel::Type::Boolean.new.cast(value) if schema == :boolean
      return value unless schema == :number

      number = Float(value, exception: false)
      number&.finite? ? number : value
    end
  end

  def to_telephony_h(user: nil, impersonation: nil)
    {
      mode: mode,
      ai_enabled: ai_enabled,
      ai_app_ref: ai_app_ref,
      ai_deployment_mode: ai_deployment_mode,
      onelink_ai_app_ref: onelink_ai_app_ref,
      fallback_ai_app_ref: fallback_ai_app_ref,
      effective_ai_app_ref: effective_ai_app_ref,
      captain_assistant_id: captain_assistant_id,
      ai_voice_settings: public_ai_voice_settings(user: user, impersonation: impersonation),
      operator_agent_ref: operator_agent_ref,
      operator_agent_aor: operator_agent_aor,
      operator_distribution_mode: operator_distribution_mode,
      fallback_mode: fallback_mode,
      fallback_message: fallback_message,
      business_hours: business_hours,
      settings: public_routing_policy_settings
    }.compact
  end

  private

  def public_routing_policy_settings
    PublicJsonFields.project(settings, PUBLIC_SETTINGS_SCHEMA).tap do |public_settings|
      if settings.is_a?(Hash) && settings.key?('call_routing')
        public_settings['call_routing'] = self.class.public_call_routing(settings['call_routing'])
      end
    end
  end

  def public_ai_voice_settings(user:, impersonation:)
    Telephony::AiVoice::PlatformPolicy.new(account: account, settings: ai_voice_settings).public_settings(user: user, impersonation: impersonation)
  end
end
