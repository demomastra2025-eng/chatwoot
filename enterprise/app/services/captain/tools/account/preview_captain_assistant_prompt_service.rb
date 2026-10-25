# frozen_string_literal: true

class Captain::Tools::Account::PreviewCaptainAssistantPromptService < Captain::Tools::Account::CaptainAssistantAdminTool
  PLATFORM_TEAM_ONLY = 'The compiled prompt is available to the platform team only'

  def self.name
    'preview_captain_assistant_prompt'
  end

  description 'Preview the compiled prompt/configuration for one Captain assistant in the current account'
  param :assistant_id, type: :integer, desc: 'Captain assistant ID', required: true

  # The compiled prompt is for the platform team only (Captain::PromptInspectorAccess): a clinic administrator
  # does not get it through MCP or Copilot either.
  def active?
    super && Captain::PromptInspectorAccess.allowed?(user: @user)
  end

  def execute(assistant_id:)
    ensure_account_administrator!
    ensure_platform_team!

    assistant = find_captain_assistant!(assistant_id)
    preview = Captain::Assistant::PromptPreviewService.new(assistant: assistant).preview
    formatted_payload(action: 'preview_captain_assistant_prompt', assistant: assistant_payload(assistant), preview: redacted_value(preview))
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def ensure_platform_team!
    raise ArgumentError, PLATFORM_TEAM_ONLY unless Captain::PromptInspectorAccess.allowed?(user: @user)
  end

  # What a clinic administrator reads when the tool refuses (MCP answer, Copilot tool result).
  def inactive_tool_error_message
    PLATFORM_TEAM_ONLY
  end
end
