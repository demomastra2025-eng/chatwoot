# frozen_string_literal: true

class Captain::Tools::Copilot::ListCaptainKnowledgeDocumentsService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'list_captain_knowledge_documents'
  end

  description 'List account-scoped Captain knowledge documents for AI Admin operations'
  param :assistant_id, type: :integer, desc: 'Optional Captain assistant ID filter', required: false
  param :status, type: :string, desc: 'Optional document status filter: in_progress, available, failed', required: false
  param :query, type: :string, desc: 'Optional search by name or source URL', required: false
  param :limit, type: :number, desc: 'Maximum documents to return, capped at 50', required: false

  def execute(assistant_id: nil, status: nil, query: nil, limit: nil)
    ensure_account_administrator!

    documents = filtered_documents(assistant_id: assistant_id, status: status, query: query)
    formatted_payload(
      action: 'list_captain_knowledge_documents',
      total_count: documents.count,
      documents: documents.limit(parse_limit(limit, default: 25, max: 50)).map { |document| document_payload(document) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def filtered_documents(assistant_id:, status:, query:)
    source_documents_scope.then do |scope|
      scope = scope.where(assistant_id: find_captain_assistant!(assistant_id).id) if assistant_id.present?
      scope = scope.where(status: status) if status.present?
      scope = scope.where('name ILIKE :query OR external_link ILIKE :query', query: "%#{query}%") if query.present?
      scope
    end
  end
end
