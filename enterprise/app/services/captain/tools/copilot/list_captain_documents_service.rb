class Captain::Tools::Copilot::ListCaptainDocumentsService < Captain::Tools::Copilot::BaseAccountTool
  def self.name
    'list_captain_documents'
  end

  description 'List visible workspace Captain knowledge documents, including safe artifact IDs for documents that can be sent as files'
  param :query, type: :string, desc: 'Optional case-insensitive search by document name or URL', required: false
  param :sendable_only, type: :boolean, desc: 'When true, return only documents with uploaded files that can be attached to messages', required: false
  param :limit, type: :integer, desc: 'Maximum number of documents to return, up to 20', required: false

  def execute(query: nil, sendable_only: nil, limit: nil)
    documents = filtered_documents(query: query, sendable_only: cast_boolean(sendable_only, default: false),
                                   limit: parse_limit(limit, default: 10, max: 20))

    formatted_payload(
      action: 'list_captain_documents',
      documents: documents.map { |document| document_payload(document) }
    )
  rescue StandardError => e
    tool_failure(e)
  end

  private

  def filtered_documents(query:, sendable_only:, limit:)
    scope = account.captain_documents.source_documents.available.visible_to_assistant(assistant.id).ordered
    scope = scope.where('name ILIKE :query OR external_link ILIKE :query', query: "%#{query}%") if query.present?
    records = scope.limit(limit)
    return records.select(&:sendable_file?) if sendable_only

    records
  end

  def document_payload(document)
    payload = {
      document_id: document.id,
      name: document.name,
      source_mode: document.source_mode,
      status: document.status,
      content_type: document.content_type,
      file_size: document.file_size,
      sendable: document.sendable_file?,
      filename: document.sendable_filename,
      external_link: document.sendable_file? ? nil : document.external_link
    }.compact

    payload[:artifact_id] = document_artifact_id(document) if document.sendable_file?
    payload
  end

  def document_artifact_id(document)
    Captain::Tools::DocumentArtifactToken.encode(
      account_id: account.id,
      assistant_id: assistant.id,
      document_id: document.id,
      blob_id: document.sendable_file_blob_id,
      status: document.status,
      document_fingerprint: document.artifact_fingerprint
    )
  end
end
