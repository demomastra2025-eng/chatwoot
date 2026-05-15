# frozen_string_literal: true

class Captain::Tools::Copilot::ListMacrosService < Captain::Tools::Copilot::SupportContentAdminTool
  def self.name
    'list_macros'
  end

  description 'List account macros with safe metadata and optionally redacted action details'
  param :query, type: :string, desc: 'Optional search by macro name', required: false
  param :visibility, type: :string, desc: 'Optional visibility filter: global or personal', required: false
  param :include_actions, type: :boolean, desc: 'Whether to include redacted macro actions', required: false
  param :limit, type: :integer, desc: 'Maximum number of macros to return', required: false

  def execute(query: nil, visibility: nil, include_actions: false, limit: nil)
    ensure_account_administrator!
    validate_macro_visibility!(visibility)

    macros = account.macros.includes(:created_by, :updated_by).order(:id)
    macros = macros.where('name ILIKE ?', "%#{query}%") if query.present?
    macros = macros.public_send(visibility) if visibility.present?

    formatted_payload(
      action: 'list_macros',
      filters: { query: query.presence, visibility: visibility.presence }.compact,
      total_count: macros.count,
      macros: macros.limit(parse_limit(limit)).map { |macro| macro_payload(macro, include_actions: cast_boolean(include_actions)) }
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
