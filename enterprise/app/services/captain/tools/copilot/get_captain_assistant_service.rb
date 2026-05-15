# frozen_string_literal: true

class Captain::Tools::Copilot::GetCaptainAssistantService < Captain::Tools::Copilot::CaptainAssistantAdminTool
  def self.name
    'get_captain_assistant'
  end

  description 'Get one Captain assistant profile, rules, config, selected tools, and context access for the current account'
  param :assistant_id, type: :integer, desc: 'Captain assistant ID', required: true

  def execute(assistant_id:)
    ensure_account_administrator!

    assistant = find_captain_assistant!(assistant_id)
    formatted_payload(action: 'get_captain_assistant', assistant: assistant_payload(assistant, include_config: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
