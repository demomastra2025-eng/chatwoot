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
    'Inbox' => %w[avatar],
    'Contact' => %w[avatar],
    'Company' => %w[avatar],
    'Reminder' => %w[files],
    'Captain::Assistant' => %w[avatar],
    'Captain::Document' => %w[pdf_file source_file]
  }.freeze

  # ActiveStorage owners that hold call recordings: they follow STORAGE_QUOTA_INCLUDE_RECORDINGS like the local files.
  RECORDING_RECORD_TYPES = %w[Call].freeze

  def initialize(account:, recordings_bytes: nil)
    @account = account
    @recordings_bytes = recordings_bytes
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

    @recordings_bytes.nil? ? account.local_recordings_bytes.to_i : @recordings_bytes.to_i
  end

  def usage_bytes
    quota_active_storage_bytes + recordings_bytes
  end

  # The physical bytes a set of blobs adds to the account: every distinct blob counts once, and a stored blob that a
  # counted attachment of the account already references adds nothing (re-attaching or reusing it stores no new bytes).
  def new_blob_bytes(blobs)
    candidates = Array(blobs).compact.uniq
    stored_ids = candidates.select(&:persisted?).map(&:id)
    owned_ids = stored_ids.empty? ? [] : active_storage_blob_scope(include_recordings: count_recordings?).where(id: stored_ids).pluck(:id)

    candidates.reject { |blob| blob.persisted? && owned_ids.include?(blob.id) }.sum { |blob| blob.byte_size.to_i }
  end

  # The bytes freed when `attachment` stops pointing at `blob`: all of them if it was the only counted owner of the
  # blob, none if another counted record still holds it.
  def released_blob_bytes(blob, attachment)
    return 0 if blob.blank? || !blob.persisted?

    owners = tenant_attachments(include_recordings: count_recordings?)&.where(blob_id: blob.id)&.pluck(:id)
    return 0 if owners.blank?

    (owners - [attachment&.id]).empty? ? blob.byte_size.to_i : 0
  end

  # Enforced for uploads by staff, imports and Captain documents. Incoming messages and calls never go through
  # this check: inbound attachments carry skip_storage_limit_validation! and inbound recordings are not validated.
  def unlimited?
    account_storage_limit.blank? && global_storage_limit.blank?
  end

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

  def self.union_blob_ids_sql(*relations)
    subqueries = relations.flat_map { |rel| rel.is_a?(Array) ? rel : [rel] }.compact.map { |rel| "(#{rel.is_a?(String) ? rel : rel.to_sql})" }
    "SELECT blob_id FROM (#{subqueries.join(' UNION ')}) AS tenant_blob_ids"
  end

  def self.source_with_variants_cte_sql(source_blob_ids_sql)
    source_sql = source_blob_ids_sql.is_a?(String) ? source_blob_ids_sql : source_blob_ids_sql.to_sql
    variant_sql = ActiveStorage::Attachment
                  .joins(
                    'INNER JOIN active_storage_variant_records ' \
                    'ON active_storage_variant_records.id = active_storage_attachments.record_id ' \
                    "AND active_storage_attachments.record_type = 'ActiveStorage::VariantRecord'"
                  )
                  .where(name: 'image')
                  .where('active_storage_variant_records.blob_id IN (SELECT blob_id FROM source_blobs)')
                  .select(:blob_id)
                  .to_sql
    "WITH source_blobs AS (#{source_sql}) SELECT blob_id FROM source_blobs UNION #{variant_sql}"
  end

  def self.blobs_for_source_and_variants(source_blob_ids, variant_blob_ids = nil)
    sql = if variant_blob_ids
            union_blob_ids_sql(source_blob_ids, variant_blob_ids)
          else
            source_blob_ids.is_a?(String) ? source_blob_ids : source_blob_ids.to_sql
          end
    ActiveStorage::Blob.where("active_storage_blobs.id IN (#{sql})")
  end

  private

  attr_reader :account

  def total_limit_bytes
    account_storage_limit.presence || global_storage_limit.presence || ChatwootApp.max_limit.to_i
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
    source_blob_ids_sql = tenant_source_blob_ids_sql(include_recordings: include_recordings)
    return ActiveStorage::Blob.none unless source_blob_ids_sql
    return self.class.blobs_for_source_and_variants(source_blob_ids_sql) unless variants_available?

    self.class.blobs_for_source_and_variants(self.class.source_with_variants_cte_sql(source_blob_ids_sql))
  end

  def tenant_source_blob_ids(include_recordings: true)
    tenant_attachments(include_recordings: include_recordings)&.select(:blob_id)&.distinct
  end

  def tenant_source_blob_ids_sql(include_recordings: true)
    scopes = tenant_attachment_scopes(include_recordings: include_recordings)
    return if scopes.empty?

    self.class.union_blob_ids_sql(scopes.map { |scope| scope.select(:blob_id) })
  end

  def tenant_attachment_scopes(include_recordings: true)
    tenant_record_type_scopes(include_recordings).filter_map do |record_type, attachment_names|
      relation = scoped_relation(record_type)
      next if relation.nil?

      scope = ActiveStorage::Attachment.where(record_type: record_type, record_id: relation)
      scope = scope.where(name: attachment_names) if attachment_names.present?
      scope
    end
  end

  def tenant_attachments(include_recordings: true)
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

    ActiveStorage::Attachment.where(predicates.reduce(&:or))
  end

  def tenant_record_type_scopes(include_recordings)
    include_recordings ? RECORD_TYPE_SCOPES : RECORD_TYPE_SCOPES.except(*RECORDING_RECORD_TYPES)
  end

  def variants_available?
    defined?(ActiveStorage::VariantRecord) && ActiveStorage::VariantRecord.table_exists?
  end

  def derived_variant_blob_ids(source_blob_ids)
    variant_records = if source_blob_ids.is_a?(String)
                        ActiveStorage::VariantRecord.where("active_storage_variant_records.blob_id IN (#{source_blob_ids})")
                      else
                        ActiveStorage::VariantRecord.where(blob_id: source_blob_ids)
                      end
    ActiveStorage::Attachment.where(
      record_type: ActiveStorage::VariantRecord.name,
      name: 'image',
      record_id: variant_records.select(:id)
    ).select(:blob_id).distinct
  end
end
