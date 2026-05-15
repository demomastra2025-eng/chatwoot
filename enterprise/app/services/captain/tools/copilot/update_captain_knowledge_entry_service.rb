# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCaptainKnowledgeEntryService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'update_captain_knowledge_entry'
  end

  description 'Update a Captain FAQ/knowledge entry. Requires operator confirmation.'
  param :entry_id, type: :integer, desc: 'Captain assistant response / knowledge entry ID', required: true
  param :question, type: :string, desc: 'Optional updated question', required: false
  param :answer, type: :string, desc: 'Optional updated answer', required: false
  param :status, type: :string, desc: 'Optional status: pending or approved', required: false
  param :assistant_id, type: :integer, desc: 'Optional destination Captain assistant ID in the same account', required: false
  param :document_id, type: :integer, desc: 'Optional Captain document ID to attach entry to', required: false

  def execute(entry_id:, **kwargs)
    ensure_account_administrator!

    entry = find_knowledge_entry!(entry_id)
    attributes = knowledge_entry_update_attributes(entry, kwargs)
    raise ArgumentError, 'No supported knowledge entry fields were provided' if attributes.blank?

    before_payload = knowledge_entry_payload(entry, include_body: true)
    entry.update!(attributes)

    formatted_payload(
      action: 'update_captain_knowledge_entry',
      entry: knowledge_entry_payload(entry.reload, include_body: true),
      previous_entry: before_payload,
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def knowledge_entry_update_attributes(entry, kwargs)
    target_assistant = kwargs[:assistant_id].present? ? find_captain_assistant!(kwargs[:assistant_id]) : entry.assistant

    {}.tap do |attributes|
      attributes[:assistant] = target_assistant if kwargs[:assistant_id].present?
      attributes[:question] = kwargs[:question] if kwargs[:question].present?
      attributes[:answer] = kwargs[:answer] if kwargs[:answer].present?
      attributes[:status] = kwargs[:status] if kwargs[:status].present?
      attributes[:documentable] = entry_documentable(entry, kwargs, target_assistant)
    end.compact
  end

  def entry_documentable(entry, kwargs, target_assistant)
    return find_document_for_assistant!(kwargs[:document_id], target_assistant) if kwargs[:document_id].present?
    return unless kwargs[:assistant_id].present? && entry.documentable_type == 'Captain::Document'
    return entry.documentable if entry.documentable&.assistant_id == target_assistant.id

    raise ActiveRecord::RecordNotFound, 'Existing knowledge entry document belongs to a different assistant'
  end
end
