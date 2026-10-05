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

  # ActiveStorage owners that hold call recordings: they follow STORAGE_QUOTA_INCLUDE_RECORDINGS like the local files.
  RECORDING_RECORD_TYPES = %w[Call].freeze

  def initialize(account:)
    @account = account
  end

  # Physical ActiveStorage bytes of the tenant, call recordings included. The storage page breakdown uses this one.
  def active_storage_bytes
    active_storage_blob_scope.sum(:byte_size).to_i
  end

  # The part of active_storage_bytes that counts towards the quota.
  def quota_active_storage_bytes
    active_storage_blob_scope(include_recordings: count_recordings?).sum(:byte_size).to_i
  end

  # Local call recordings live outside ActiveStorage. They stay out of the quota (and the upload check) by default,
  # as before; STORAGE_QUOTA_INCLUDE_RECORDINGS=true opts them in once the accounts with a limit have been reviewed.
  def count_recordings?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('STORAGE_QUOTA_INCLUDE_RECORDINGS', 'false'))
  end

  def recordings_bytes
    return 0 unless count_recordings? && account.respond_to?(:local_recordings_bytes)

    account.local_recordings_bytes.to_i
  end

  def usage_bytes
    quota_active_storage_bytes + recordings_bytes
  end

  # Enforced for uploads by staff, imports and Captain documents. Incoming messages and calls never go through
  # this check: inbound attachments carry skip_storage_limit_validation! and inbound recordings are not validated.
  def within_limit?(extra_bytes: 0, released_bytes: 0)
    return true if unlimited?

    projected_usage = usage_bytes + extra_bytes.to_i - released_bytes.to_i
    projected_usage <= total_limit_bytes
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
  def active_storage_blob_scope(include_recordings: true)
    source_blob_ids = tenant_source_blob_ids(include_recordings: include_recordings)
    return ActiveStorage::Blob.none unless source_blob_ids

    owned_blobs = ActiveStorage::Blob.where(id: source_blob_ids)
    return owned_blobs unless variants_available?

    owned_blobs.or(ActiveStorage::Blob.where(id: derived_variant_blob_ids(source_blob_ids)))
  end

  def tenant_source_blob_ids(include_recordings: true)
    predicates = tenant_record_type_scopes(include_recordings).filter_map do |record_type, attachment_names|
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

  def tenant_record_type_scopes(include_recordings)
    include_recordings ? RECORD_TYPE_SCOPES : RECORD_TYPE_SCOPES.except(*RECORDING_RECORD_TYPES)
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
