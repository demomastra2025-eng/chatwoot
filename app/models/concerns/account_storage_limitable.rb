# frozen_string_literal: true

module AccountStorageLimitable
  STORAGE_ALERT_ENQUEUE_INTERVAL = 5.minutes.to_i

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

  # Automatic writers of customer-facing assets (an avatar fetched from a channel) exempt one record from the check:
  # the storage limit never blocks inbound traffic. Attachment defines its own flag with the same contract.
  def skip_storage_limit_validation!
    @skip_storage_limit_validation = true
    self
  end

  def skip_storage_limit_validation?
    ActiveModel::Type::Boolean.new.cast(@skip_storage_limit_validation)
  end

  private

  def validate_storage_limit_for_attachment(attachment_name)
    change = attachment_changes[attachment_name.to_s]
    return if change.blank? || skip_storage_validation?

    blobs = changed_blobs(change)
    return if blobs.sum { |blob| blob.byte_size.to_i }.zero?

    account = storage_limit_account
    return if account.blank?

    storage_service = AccountLimits::StorageUsageService.new(account: account)
    # Only blobs the account does not hold yet grow its usage: ActiveStorage carries the files an owner already has
    # in the change, and a blob that another counted owner holds is not stored a second time.
    extra_bytes = storage_service.new_blob_bytes(blobs)
    return if extra_bytes <= 0

    released_bytes = replaced_blob_bytes(change, attachment_name, storage_service, blobs)
    return if storage_service.within_limit?(extra_bytes: extra_bytes, released_bytes: released_bytes)

    trigger_storage_alert(account)
    errors.add(attachment_name, AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE)
  end

  def skip_storage_validation?
    respond_to?(:skip_storage_limit_validation?) && skip_storage_limit_validation?
  end

  # A rejected upload asks the storage-alert job to tell the account owners; it is throttled per account.
  def trigger_storage_alert(account)
    return unless Redis::Alfred.set("account:#{account.id}:storage_alert_enqueued", '1', nx: true, ex: STORAGE_ALERT_ENQUEUE_INTERVAL)

    Accounts::StorageThresholdAlertJob.perform_later(account.id)
  rescue StandardError => e
    Rails.logger.warn("[AccountStorageLimitable] Alert dispatch failed: #{e.message}")
  end

  def storage_limit_account
    return account if respond_to?(:account) && account.present?
    return Account.find_by(id: account_id) if respond_to?(:account_id) && account_id.present?

    nil
  end

  def changed_blobs(change)
    blobs = if change.respond_to?(:blobs)
              change.blobs
            elsif change.respond_to?(:blob)
              [change.blob]
            else
              []
            end

    Array(blobs).compact
  end

  # A replaced blob frees its bytes only when this attachment was its last counted owner and the new value does not
  # keep it.
  def replaced_blob_bytes(change, attachment_name, storage_service, new_blobs)
    return 0 unless change.class.name.end_with?('CreateOne')

    old_blob = public_send("#{attachment_name}_blob")
    return 0 if old_blob.blank? || new_blobs.include?(old_blob)

    storage_service.released_blob_bytes(old_blob, public_send("#{attachment_name}_attachment"))
  end
end
