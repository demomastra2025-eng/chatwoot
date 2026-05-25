# frozen_string_literal: true

class Captain::Tools::Copilot::GetCaptainKnowledgeEntryService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'get_captain_knowledge_entry'
  end

  description 'Get one Captain FAQ/knowledge entry with redacted question and answer'
  param :entry_id, type: :integer, desc: 'Captain assistant response / knowledge entry ID', required: true

  def execute(entry_id:)
    ensure_account_administrator!

    entry = find_knowledge_entry!(entry_id)
    formatted_payload(action: 'get_captain_knowledge_entry', entry: knowledge_entry_payload(entry, include_body: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
