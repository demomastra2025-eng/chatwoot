# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCaptainAssistantService < Captain::Tools::Copilot::CaptainAssistantAdminTool
  def self.name
    'update_captain_assistant'
  end

  CONFIG_JSON_DESCRIPTION = 'Optional JSON object with supported config fields such as temperature, tool_access, context_access, ' \
                            'rules, feature_faq, feature_memory, voice_settings'

  description 'Update one Captain assistant profile/config/rules/tool access in the current account. Requires operator confirmation.'
  param :assistant_id, type: :integer, desc: 'Captain assistant ID', required: true
  param :name, type: :string, desc: 'Optional assistant name', required: false
  param :description, type: :string, desc: 'Optional assistant instructions/description', required: false
  param :usage_mode, type: :string, desc: 'Optional usage mode: external_agent or internal_assistant', required: false
  param :config_json, type: :string, desc: CONFIG_JSON_DESCRIPTION, required: false
  param :response_guidelines_json, type: :string, desc: 'Optional JSON array of response guideline entries', required: false
  param :guardrails_json, type: :string, desc: 'Optional JSON array of guardrail entries', required: false

  def execute(assistant_id:, **kwargs)
    ensure_account_administrator!

    assistant = find_captain_assistant!(assistant_id)
    attributes = build_update_attributes(assistant: assistant, kwargs: kwargs)
    raise ArgumentError, 'No supported assistant fields were provided' if attributes.blank?

    before_payload = assistant_payload(assistant, include_config: true)
    assistant.update!(attributes)

    formatted_payload(
      action: 'update_captain_assistant',
      assistant: assistant_payload(assistant.reload, include_config: true),
      previous_assistant: before_payload,
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def build_update_attributes(assistant:, kwargs:)
    profile_update_attributes(kwargs)
      .merge(config_update_attributes(assistant, kwargs))
      .merge(rules_update_attributes(kwargs))
  end

  def profile_update_attributes(kwargs)
    {}.tap do |attributes|
      attributes[:name] = kwargs[:name] if kwargs[:name].present?
      attributes[:description] = kwargs[:description] if kwargs[:description].present?
      attributes[:usage_mode] = kwargs[:usage_mode] if kwargs[:usage_mode].present?
    end
  end

  def config_update_attributes(assistant, kwargs)
    return {} if kwargs[:config_json].blank?

    { config: merged_config(assistant, kwargs[:config_json]) }
  end

  def rules_update_attributes(kwargs)
    attributes = {}
    response_guidelines = parse_json_array(kwargs[:response_guidelines_json], field_name: 'response_guidelines_json')
    guardrails = parse_json_array(kwargs[:guardrails_json], field_name: 'guardrails_json')
    attributes[:response_guidelines] = response_guidelines unless response_guidelines.nil?
    attributes[:guardrails] = guardrails unless guardrails.nil?
    attributes
  end

  def merged_config(assistant, config_json)
    current_config = assistant.config || {}
    current_config.deep_stringify_keys.merge(filtered_config_updates(config_json))
  end
end
