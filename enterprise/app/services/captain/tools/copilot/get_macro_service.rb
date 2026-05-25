# frozen_string_literal: true

class Captain::Tools::Copilot::GetMacroService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'get_macro'
  end

  description 'Get one account macro with redacted action details'
  param :macro_id, type: :integer, desc: 'Macro ID from list_macros', required: true

  def execute(macro_id:)
    ensure_account_administrator!

    macro = macro!(macro_id)

    formatted_payload(
      action: 'get_macro',
      macro: macro_payload(macro, include_actions: true),
      supported_actions: Macro::ACTIONS_ATTRS
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
