# frozen_string_literal: true

class Captain::UiActionContract
  MAX_ACTIONS = 5
  MAX_INPUT_ACTIONS = 20
  MAX_LABEL_LENGTH = 80
  MAX_TARGET_ID_LENGTH = 500
  MAX_RAW_FIELD_LENGTH = 2000

  SIMPLE_ACTION_TYPES = %w[
    open_home open_contacts open_companies open_tasks open_deals open_notifications
    open_outbound open_outbound_personal open_touch_plans open_templates open_automation_rules
    open_macros open_canned_responses open_inboxes_settings open_agents_settings open_teams_settings
    open_labels_settings open_account_settings open_scheduling_settings open_assignment_policies
    open_integrations open_webhooks open_kaspi_pay_settings open_reports open_conversation_reports
    open_sla_reports open_csat_reports open_help_center open_captain_settings open_captain_assistants
    open_captain_observability
  ].freeze

  TARGET_ACTION_TYPES = %w[
    open_conversation open_inbox open_inbox_settings open_team_conversations open_label_conversations
    open_contact open_company open_deal open_task open_captain_responses open_captain_documents
    open_captain_tools open_captain_scenarios open_captain_playground open_captain_channels
    open_captain_assistant_settings open_captain_prompts create_contact create_company create_task create_deal
  ].freeze
  OPTIONAL_TARGET_ACTION_TYPES = %w[create_contact create_company create_task create_deal].freeze
  REQUIRED_TARGET_ACTION_TYPES = (TARGET_ACTION_TYPES - OPTIONAL_TARGET_ACTION_TYPES).freeze

  SUPPORTED_TYPES = (SIMPLE_ACTION_TYPES + TARGET_ACTION_TYPES).freeze
  SUPPORTED_TYPES_DESCRIPTION = SUPPORTED_TYPES.join(', ')

  class << self
    def normalize(actions)
      return [] unless actions.is_a?(Array)

      normalized_actions = []
      actions.first(MAX_INPUT_ACTIONS).each do |action|
        normalized_action = normalize_action(action)
        next unless normalized_action

        normalized_actions << normalized_action
        break if normalized_actions.length >= MAX_ACTIONS
      end
      normalized_actions
    end

    private

    def normalize_action(action)
      return unless action.respond_to?(:[])

      type = action_value(action, 'type').to_s.strip
      return unless SUPPORTED_TYPES.include?(type)

      label = strip_markup(action_value(action, 'label')).first(MAX_LABEL_LENGTH)
      return if label.blank?

      target_id = target_id(action)
      return if REQUIRED_TARGET_ACTION_TYPES.include?(type) && target_id.blank?

      {
        'type' => type,
        'label' => label,
        'target_id' => target_id
      }
    end

    def target_id(action)
      raw_target = action_value(action, 'target_id') ||
                   action_value(action, 'targetId') ||
                   action_value(action, 'entity_id') ||
                   action_value(action, 'entityId') || ''
      strip_markup(raw_target).first(MAX_TARGET_ID_LENGTH)
    end

    def action_value(action, key)
      return action[key] if action.respond_to?(:key?) && action.key?(key)

      symbol_key = key.to_sym
      action[symbol_key] if action.respond_to?(:key?) && action.key?(symbol_key)
    end

    def strip_markup(value)
      value.to_s.first(MAX_RAW_FIELD_LENGTH)
           .gsub(/<[^>]*>/, '')
           .gsub(/[\r\n]+/, ' ')
           .strip
    end
  end
end
