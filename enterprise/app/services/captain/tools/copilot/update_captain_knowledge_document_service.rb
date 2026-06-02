# frozen_string_literal: true

class Captain::Tools::Copilot::UpdateCaptainKnowledgeDocumentService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'update_captain_knowledge_document'
  end

  description 'Update a Captain knowledge document name, assistant assignment, visibility, or FAQ generation flag. Requires operator confirmation.'
  param :document_id, type: :integer, desc: 'Captain document ID', required: true
  param :assistant_id, type: :integer, desc: 'Optional destination Captain assistant ID in the same account', required: false
  param :name, type: :string, desc: 'Optional document name', required: false
  param :visibility, type: :string, desc: 'Optional visibility: general or personal', required: false
  param :faq_generation_enabled, type: :boolean, desc: 'Optional FAQ generation flag', required: false

  def execute(document_id:, **kwargs)
    ensure_account_administrator!

    document = find_source_document!(document_id)
    attributes = knowledge_document_update_attributes(kwargs)
    raise ArgumentError, 'No supported document fields were provided' if attributes.blank?

    before_payload = document_payload(document, include_details: true)
    ActiveRecord::Base.transaction do
      document.update!(attributes)
      reconcile_document_entries!(document) if attributes.key?(:assistant) || attributes.key?(:visibility)
    end

    formatted_payload(
      action: 'update_captain_knowledge_document',
      document: document_payload(document.reload, include_details: true),
      previous_document: before_payload,
      updated_fields: attributes.keys.map(&:to_s)
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def knowledge_document_update_attributes(kwargs)
    {}.tap do |attributes|
      attributes[:assistant] = find_captain_assistant!(kwargs[:assistant_id]) if kwargs[:assistant_id].present?
      attributes[:name] = kwargs[:name] if kwargs[:name].present?
      attributes[:visibility] = normalize_knowledge_visibility(kwargs[:visibility]) if kwargs[:visibility].present?
      attributes[:faq_generation_enabled] = cast_boolean(kwargs[:faq_generation_enabled]) unless kwargs[:faq_generation_enabled].nil?
    end
  end

  def reconcile_document_entries!(document)
    document.responses.find_each do |entry|
      entry.update!(assistant: document.assistant, account: account, visibility: document.visibility)
    end
  end
end
