# frozen_string_literal: true

class Captain::Tools::Copilot::CreateMacroService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'create_macro'
  end

  description 'Create an account macro from explicit actions JSON'
  param :name, type: :string, desc: 'Macro name', required: true
  param :actions_json, type: :string, desc: 'JSON array of macro actions. Use get_macro/list_macros to inspect examples.', required: true
  param :visibility,
        type: :string,
        desc: 'Macro visibility: global or personal. Defaults to global for account-level assistant admin control.',
        required: false

  def execute(name:, actions_json:, visibility: 'global')
    ensure_account_administrator!
    validate_macro_visibility!(visibility)

    macro = account.macros.new(
      name: name.to_s.strip,
      visibility: visibility.presence || 'global',
      actions: parse_actions_json(actions_json),
      created_by: @user,
      updated_by: @user
    )
    macro.save!

    formatted_payload(
      action: 'create_macro',
      macro: macro_payload(macro, include_actions: true),
      supported_actions: Macro::ACTIONS_ATTRS
    )
  rescue ActiveRecord::RecordInvalid => e
    tool_failure(ArgumentError.new(e.record.errors.full_messages.join(', ')))
  rescue StandardError => e
    tool_failure(e)
  end
end
