# frozen_string_literal: true

class Captain::Tools::Copilot::ListCaptainAssistantsService < Captain::Tools::Copilot::CaptainAssistantAdminTool
  def self.name
    'list_captain_assistants'
  end

  description 'List Captain assistants in the current account for AI Admin operations'
  param :limit, type: :number, desc: 'Maximum assistants to return, capped at 50', required: false

  def execute(limit: nil)
    ensure_account_administrator!

    assistants = account.captain_assistants.external_agent.order(updated_at: :desc)

    formatted_payload(
      action: 'list_captain_assistants',
      total_count: assistants.count,
      assistants: assistants.limit(parse_limit(limit, default: 25, max: 50)).map { |assistant| assistant_payload(assistant) }
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
