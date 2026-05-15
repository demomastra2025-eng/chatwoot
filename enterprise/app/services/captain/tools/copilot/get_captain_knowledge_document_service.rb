# frozen_string_literal: true

class Captain::Tools::Copilot::GetCaptainKnowledgeDocumentService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'get_captain_knowledge_document'
  end

  description 'Get one account-scoped Captain knowledge document with safe redacted metadata'
  param :document_id, type: :integer, desc: 'Captain document ID', required: true

  def execute(document_id:)
    ensure_account_administrator!

    document = find_document!(document_id)
    formatted_payload(action: 'get_captain_knowledge_document', document: document_payload(document, include_details: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
