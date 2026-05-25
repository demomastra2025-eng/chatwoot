# frozen_string_literal: true

class Captain::Tools::Copilot::ListCaptainKnowledgeEntriesService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'list_captain_knowledge_entries'
  end

  description 'List Captain FAQ/knowledge entries in the current account for AI Admin operations'
  param :assistant_id, type: :integer, desc: 'Optional Captain assistant ID filter', required: false
  param :document_id, type: :integer, desc: 'Optional Captain document ID filter', required: false
  param :status, type: :string, desc: 'Optional status filter: pending or approved', required: false
  param :query, type: :string, desc: 'Optional search by question or answer', required: false
  param :limit, type: :number, desc: 'Maximum entries to return, capped at 50', required: false

  def execute(assistant_id: nil, document_id: nil, status: nil, query: nil, limit: nil)
    ensure_account_administrator!

    entries = filtered_entries(assistant_id: assistant_id, document_id: document_id, status: status, query: query)
    formatted_payload(
      action: 'list_captain_knowledge_entries',
      total_count: entries.count,
      entries: entries.limit(parse_limit(limit, default: 25, max: 50)).map { |entry| knowledge_entry_payload(entry) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def filtered_entries(assistant_id:, document_id:, status:, query:)
    knowledge_entries_scope.then do |scope|
      scope = scope.where(assistant_id: find_captain_assistant!(assistant_id).id) if assistant_id.present?
      scope = scope.where(documentable: find_document!(document_id)) if document_id.present?
      scope = scope.where(status: status) if status.present?
      scope = scope.where('question ILIKE :query OR answer ILIKE :query', query: "%#{query}%") if query.present?
      scope
    end
  end
end
