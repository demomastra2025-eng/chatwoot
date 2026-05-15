# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateMacroService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'update_macro'
  end

  description 'Update an account macro name, visibility, or actions JSON'
  param :macro_id, type: :integer, desc: 'Macro ID from list_macros', required: true
  param :name, type: :string, desc: 'New macro name', required: false
  param :visibility, type: :string, desc: 'New visibility: global or personal', required: false
  param :actions_json, type: :string, desc: 'New JSON array of macro actions', required: false

  def execute(macro_id:, **kwargs)
    ensure_account_administrator!

    macro = macro!(macro_id)
    attrs = build_macro_attrs(kwargs)
    raise ArgumentError, 'At least one field is required' if attrs.blank?

    macro.update!(attrs.merge(updated_by: @user))

    formatted_payload(
      action: 'update_macro',
      macro: macro_payload(macro, include_actions: true),
      supported_actions: Macro::ACTIONS_ATTRS
    )
  rescue ActiveRecord::RecordInvalid => e
    tool_failure(ArgumentError.new(e.record.errors.full_messages.join(', ')))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def build_macro_attrs(kwargs)
    attrs = {}
    attrs[:name] = kwargs[:name].to_s.strip if kwargs[:name].present?
    if kwargs.key?(:visibility) && kwargs[:visibility].present?
      validate_macro_visibility!(kwargs[:visibility])
      attrs[:visibility] = kwargs[:visibility].to_s
    end
    attrs[:actions] = parse_actions_json(kwargs[:actions_json]) if kwargs.key?(:actions_json) && !kwargs[:actions_json].nil?
    attrs
  end
end
