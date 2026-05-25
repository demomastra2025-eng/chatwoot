# frozen_string_literal: true

class Captain::Tools::Copilot::ListCaptainAssistantsService < Captain::Tools::Copilot::CaptainAssistantAdminTool
  def self.name
    'list_captain_assistants'
  end

  description 'List Captain assistants in the current account for AI Admin operations'
  param :usage_mode, type: :string, desc: 'Optional usage mode filter: external_agent or internal_assistant', required: false
  param :limit, type: :number, desc: 'Maximum assistants to return, capped at 50', required: false

  def execute(usage_mode: nil, limit: nil)
    ensure_account_administrator!

    assistants = account.captain_assistants.order(updated_at: :desc)
    assistants = assistants.where(usage_mode: usage_mode) if usage_mode.present?

    formatted_payload(
      action: 'list_captain_assistants',
      total_count: assistants.count,
      assistants: assistants.limit(parse_limit(limit, default: 25, max: 50)).map { |assistant| assistant_payload(assistant) }
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
