# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteMacroService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'delete_macro'
  end

  description 'Delete a macro from the current account'
  param :macro_id, type: :integer, desc: 'Macro ID from list_macros', required: true

  def execute(macro_id:)
    ensure_account_administrator!

    macro = macro!(macro_id)
    payload = macro_payload(macro, include_actions: false)
    macro.destroy!

    formatted_payload(
      action: 'delete_macro',
      deleted: true,
      macro: payload
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
