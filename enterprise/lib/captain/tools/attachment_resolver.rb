class Captain::Tools::AttachmentResolver
  def initialize(account:, assistant:)
    @account = account
    @assistant = assistant
  end

  def resolve(attachment_ids: [], artifact_ids: [])
    direct_attachment_ids = Array(attachment_ids).filter_map do |attachment_id|
      validate_account_scoped_blob!(attachment_id.to_s.presence)
    end
    artifact_attachment_ids = Array(artifact_ids).filter_map do |artifact_id|
      validate_account_scoped_blob!(artifact_materializer.materialize!(artifact_id))
    end

    direct_attachment_ids + artifact_attachment_ids
  end

  private

  attr_reader :account, :assistant

  def validate_account_scoped_blob!(signed_blob_id)
    return if signed_blob_id.blank?

    blob = ActiveStorage::Blob.find_signed!(signed_blob_id)
    return signed_blob_id if account_scoped_blob?(blob)

    raise ArgumentError, 'Attachment does not belong to the current account'
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
    raise ArgumentError, 'Attachment not found'
  end

  def account_scoped_blob?(blob)
    blob_metadata_account_id(blob) == account.id || blob_attached_to_account_record?(blob)
  end

  def blob_metadata_account_id(blob)
    metadata = blob.metadata.to_h.with_indifferent_access
    metadata[:account_id].to_i if metadata[:account_id].present?
  end

  def blob_attached_to_account_record?(blob)
    ActiveStorage::Attachment.includes(:record).where(blob_id: blob.id).any? do |attachment|
      record_account_id(attachment.record) == account.id
    end
  end

  def record_account_id(record)
    return unless record.respond_to?(:account_id)

    record.account_id
  end

  def artifact_materializer
    @artifact_materializer ||= Captain::Tools::HttpArtifactMaterializer.new(account: account, assistant: assistant)
  end
end
