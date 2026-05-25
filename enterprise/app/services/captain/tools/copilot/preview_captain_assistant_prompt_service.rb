# frozen_string_literal: true

class Captain::Tools::Copilot::PreviewCaptainAssistantPromptService < Captain::Tools::Copilot::CaptainAssistantAdminTool
  def self.name
    'preview_captain_assistant_prompt'
  end

  description 'Preview the compiled prompt/configuration for one Captain assistant in the current account'
  param :assistant_id, type: :integer, desc: 'Captain assistant ID', required: true

  def execute(assistant_id:)
    ensure_account_administrator!

    assistant = find_captain_assistant!(assistant_id)
    preview = Captain::Assistant::PromptPreviewService.new(assistant: assistant).preview
    formatted_payload(action: 'preview_captain_assistant_prompt', assistant: assistant_payload(assistant), preview: redacted_value(preview))
  rescue StandardError => e
    tool_failure(e)
  end
end
