# frozen_string_literal: true

module AccountStorageLimitable
  extend ActiveSupport::Concern

  class_methods do
    def account_storage_attachments(*attachment_names)
      validate do
        attachment_names.each do |attachment_name|
          validate_storage_limit_for_attachment(attachment_name)
        end
      end
    end
  end

  private

  def validate_storage_limit_for_attachment(attachment_name)
    change = attachment_changes[attachment_name.to_s]
    return if change.blank?
    return if respond_to?(:skip_storage_limit_validation?) && skip_storage_limit_validation?

    extra_bytes = changed_blob_bytes(change)
    return if extra_bytes <= 0

    account = storage_limit_account
    return if account.blank?

    released_bytes = replaced_blob_bytes(change, attachment_name)
    storage_service = AccountLimits::StorageUsageService.new(account: account)
    return if storage_service.within_limit?(extra_bytes: extra_bytes, released_bytes: released_bytes)

    errors.add(attachment_name, AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE)
  end

  def storage_limit_account
    return account if respond_to?(:account) && account.present?
    return Account.find_by(id: account_id) if respond_to?(:account_id) && account_id.present?

    nil
  end

  def changed_blob_bytes(change)
    blobs = if change.respond_to?(:blobs)
              change.blobs
            elsif change.respond_to?(:blob)
              [change.blob]
            else
              []
            end

    Array(blobs).sum { |blob| blob&.byte_size.to_i }
  end

  def replaced_blob_bytes(change, attachment_name)
    return 0 unless change.class.name.end_with?('CreateOne')

    public_send("#{attachment_name}_blob")&.byte_size.to_i
  end
end
