# frozen_string_literal: true

class AccountLimits::StorageUsageService
  LimitExceeded = Class.new(StandardError)

  LIMIT_EXCEEDED_MESSAGE = 'Account storage limit exceeded'

  RECORD_TYPE_SCOPES = {
    'Attachment' => nil,
    'Account' => %w[contacts_export logo],
    'CampaignAudienceImport' => %w[import_file],
    'Call' => %w[recording recording_manifest recording_tracks decoded_recording_manifest decoded_recording_chunks],
    'ContactChannelProfile' => %w[avatar],
    'Whatsapp::TemplateMediaSource' => %w[file],
    'Macro' => %w[files],
    'AutomationRule' => %w[files],
    'Portal' => %w[logo],
    'DataImport' => %w[failed_records import_file],
    'AgentBot' => %w[avatar],
    'Inbox' => %w[avatar],
    'Contact' => %w[avatar],
    'Company' => %w[avatar],
    'Reminder' => %w[files],
    'Captain::Assistant' => %w[avatar],
    'Captain::Document' => %w[pdf_file source_file]
  }.freeze

  def initialize(account:)
    @account = account
  end

  def active_storage_bytes
    active_storage_blob_scope.sum(:byte_size).to_i
  end

  # Local call recordings live outside ActiveStorage and are included in physical usage totals.
  def count_recordings?
    true
  end

  def recordings_bytes
    return 0 unless count_recordings? && account.respond_to?(:local_recordings_bytes)

    account.local_recordings_bytes.to_i
  end

  def usage_bytes
    active_storage_bytes + recordings_bytes
  end

  # Storage is informational: uploads, imports, messages and attachments remain available above the limit.
  def within_limit?(**)
    true
  end

  def summary
    consumed = usage_bytes

    {
      total_count: total_limit_bytes,
      current_available: unlimited? ? ChatwootApp.max_limit.to_i : (total_limit_bytes - consumed).clamp(0, total_limit_bytes),
      consumed: consumed,
      unlimited: unlimited?
    }
  end

  private

  attr_reader :account

  def total_limit_bytes
    account_storage_limit.presence || global_storage_limit.presence || ChatwootApp.max_limit.to_i
  end

  def unlimited?
    account_storage_limit.blank? && global_storage_limit.blank?
  end

  def account_storage_limit
    account[:limits]&.[]('storage_bytes')
  end

  def global_storage_limit
    GlobalConfig.get('ACCOUNT_STORAGE_BYTES_LIMIT')['ACCOUNT_STORAGE_BYTES_LIMIT']
  end

  def scoped_relation(record_type)
    model = record_type.safe_constantize
    return if model.blank?

    case record_type
    when 'Account'
      model.where(id: account.id).select(:id)
    when 'Whatsapp::TemplateMediaSource'
      model.where(whatsapp_channel_id: Channel::Whatsapp.where(account_id: account.id).select(:id)).select(:id)
    else
      return if model.column_names.exclude?('account_id')

      model.where(account_id: account.id).select(:id)
    end
  end

  # Count each physical blob once per tenant, including generated images only when their source blob
  # is owned by this account. Shared User avatars remain excluded from tenant totals.
  def active_storage_blob_scope
    source_blob_ids = tenant_source_blob_ids
    return ActiveStorage::Blob.none unless source_blob_ids

    owned_blobs = ActiveStorage::Blob.where(id: source_blob_ids)
    return owned_blobs unless variants_available?

    owned_blobs.or(ActiveStorage::Blob.where(id: derived_variant_blob_ids(source_blob_ids)))
  end

  def tenant_source_blob_ids
    predicates = RECORD_TYPE_SCOPES.filter_map do |record_type, attachment_names|
      relation = scoped_relation(record_type)
      next if relation.nil?

      attachment_table = ActiveStorage::Attachment.arel_table
      predicate = attachment_table[:record_type].eq(record_type)
                                                .and(attachment_table[:record_id].in(relation.arel))
      predicate = predicate.and(attachment_table[:name].in(attachment_names)) if attachment_names.present?
      predicate
    end
    return if predicates.empty?

    ActiveStorage::Attachment.where(predicates.reduce(&:or)).select(:blob_id).distinct
  end

  def variants_available?
    defined?(ActiveStorage::VariantRecord) && ActiveStorage::VariantRecord.table_exists?
  end

  def derived_variant_blob_ids(source_blob_ids)
    ActiveStorage::Attachment.where(
      record_type: ActiveStorage::VariantRecord.name,
      name: 'image',
      record_id: ActiveStorage::VariantRecord.where(blob_id: source_blob_ids).select(:id)
    ).select(:blob_id).distinct
  end
end
