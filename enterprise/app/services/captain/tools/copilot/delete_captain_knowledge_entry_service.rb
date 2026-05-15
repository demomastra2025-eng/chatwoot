# frozen_string_literal: true

class Captain::Tools::Copilot::DeleteCaptainKnowledgeEntryService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'delete_captain_knowledge_entry'
  end

  description 'Delete a Captain FAQ/knowledge entry. Requires operator confirmation.'
  param :entry_id, type: :integer, desc: 'Captain assistant response / knowledge entry ID', required: true

  def execute(entry_id:)
    ensure_account_administrator!

    entry = find_knowledge_entry!(entry_id)
    before_payload = knowledge_entry_payload(entry, include_body: true)
    entry.destroy!

    formatted_payload(action: 'delete_captain_knowledge_entry', deleted_entry: before_payload)
  rescue StandardError => e
    tool_failure(e)
  end
end
