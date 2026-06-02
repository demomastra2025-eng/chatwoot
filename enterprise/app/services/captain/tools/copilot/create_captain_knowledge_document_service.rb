# frozen_string_literal: true

class Captain::Tools::Copilot::CreateCaptainKnowledgeDocumentService < Captain::Tools::Copilot::CaptainKnowledgeAdminTool
  def self.name
    'create_captain_knowledge_document'
  end

  description 'Create a workspace remote URL Captain knowledge document. Requires operator confirmation.'
  param :assistant_id, type: :integer, desc: 'Optional Captain assistant ID for personal documents', required: false
  param :name, type: :string, desc: 'Document name', required: true
  param :external_link, type: :string, desc: 'Remote source URL. Secret query strings are redacted from tool output.', required: true
  param :source_mode, type: :string, desc: 'Optional source mode: legacy_url, selected_pages, pdf_url, file_url', required: false
  param :faq_generation_enabled, type: :boolean, desc: 'Whether to generate FAQ entries from the document. Defaults to true.', required: false
  param :visibility, type: :string, desc: 'Optional visibility: general or personal. Defaults to general.', required: false
  param :selected_urls_json, type: :string, desc: 'Optional JSON array of selected URLs for selected_pages mode', required: false
  param :import_profile_json, type: :string, desc: 'Optional JSON object with crawl/import profile settings', required: false

  def execute(name:, external_link:, assistant_id: nil, **kwargs)
    ensure_account_administrator!

    document_assistant = find_captain_assistant!(assistant_id) if assistant_id.present?
    document = Captain::Document.create!(
      create_document_attributes(
        assistant: document_assistant,
        kwargs: kwargs.merge(name: name, external_link: external_link)
      )
    )

    formatted_payload(action: 'create_captain_knowledge_document', document: document_payload(document.reload, include_details: true))
  rescue StandardError => e
    tool_failure(e)
  end
end
