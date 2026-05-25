# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteCaptainKnowledgeDocumentService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'delete_captain_knowledge_document'
  end

  description 'Delete a source Captain knowledge document and its derived FAQ/child documents. Requires operator confirmation.'
  param :document_id, type: :integer, desc: 'Captain source document ID', required: true

  def execute(document_id:)
    ensure_account_administrator!

    document = find_source_document!(document_id)
    before_payload = document_payload(document, include_details: true)
    document.destroy!

    formatted_payload(action: 'delete_captain_knowledge_document', deleted_document: before_payload)
  rescue StandardError => e
    tool_failure(e)
  end
end
