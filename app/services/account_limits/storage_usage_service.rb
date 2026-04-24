class AccountLimits::StorageUsageService
  LimitExceeded = Class.new(StandardError)

  LIMIT_EXCEEDED_MESSAGE = 'Account storage limit exceeded'.freeze

  RECORD_TYPE_SCOPES = {
    'Attachment' => nil,
    'Macro' => %w[files],
    'AutomationRule' => %w[files],
    'Portal' => %w[logo],
    'DataImport' => %w[import_file],
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

  def usage_bytes
    RECORD_TYPE_SCOPES.sum do |record_type, attachment_names|
      relation = scoped_relation(record_type)
      next 0 if relation.nil?

      attachments = ActiveStorage::Attachment.joins(:blob)
                                             .where(record_type: record_type)
                                             .where("#{ActiveStorage::Attachment.table_name}.record_id IN (#{relation.to_sql})")
      attachments = attachments.where(name: attachment_names) if attachment_names.present?
      attachments.sum('active_storage_blobs.byte_size')
    end
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

  private

  attr_reader :account

  def total_limit_bytes
    account_storage_limit.presence ||
      global_storage_limit.presence ||
      ChatwootApp.max_limit.to_i
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
    return if model.blank? || !model.column_names.include?('account_id')

    model.where(account_id: account.id).select(:id)
  end
end
