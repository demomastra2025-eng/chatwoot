# frozen_string_literal: true

class Captain::Tools::Copilot::CreateCaptainKnowledgeEntryService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'create_captain_knowledge_entry'
  end

  description 'Create a manual Captain FAQ/knowledge entry. Requires operator confirmation.'
  param :assistant_id, type: :integer, desc: 'Captain assistant ID', required: true
  param :question, type: :string, desc: 'Knowledge entry question', required: true
  param :answer, type: :string, desc: 'Knowledge entry answer', required: true
  param :status, type: :string, desc: 'Optional status: pending or approved. Defaults to approved.', required: false
  param :document_id, type: :integer, desc: 'Optional Captain document ID to attach this generated entry to', required: false

  def execute(assistant_id:, question:, answer:, status: nil, document_id: nil)
    ensure_account_administrator!

    entry_assistant = find_captain_assistant!(assistant_id)
    entry = Captain::AssistantResponse.create!(
      assistant: entry_assistant,
      account: account,
      question: question,
      answer: answer,
      status: status.presence || 'approved',
      documentable: document_id.present? ? find_document_for_assistant!(document_id, entry_assistant) : @user
    )

    formatted_payload(action: 'create_captain_knowledge_entry', entry: knowledge_entry_payload(entry.reload, include_body: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
