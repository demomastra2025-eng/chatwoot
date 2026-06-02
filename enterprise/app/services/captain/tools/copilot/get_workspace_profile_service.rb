# frozen_string_literal: true

class Captain::Tools::Copilot::GetWorkspaceProfileService < Captain::Tools::Copilot::WorkspaceProfileTool
  def self.name
    'get_workspace_profile'
  end

  description 'Get the current OneLink workspace profile, safe account metadata, editable settings, and operational counts'

  def execute
    ensure_account_administrator!

    formatted_payload(
      action: 'get_workspace_profile',
      workspace: workspace_profile_payload,
      editable_fields: editable_workspace_fields
    )
  rescue StandardError => e
    tool_failure(e)
  end
end
