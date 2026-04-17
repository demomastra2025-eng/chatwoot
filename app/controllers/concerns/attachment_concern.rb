module AttachmentConcern
  extend ActiveSupport::Concern

  def validate_and_prepare_attachments(actions, record = nil)
    blobs = []
    return [blobs, actions, nil] if actions.blank?

    sanitized = actions.map do |action|
      next action unless action[:action_name] == 'send_attachment'

      result = process_attachment_action(action, record, blobs)
      return [nil, nil, I18n.t('errors.attachments.invalid')] unless result

      result
    end

    return [blobs, sanitized, nil] if blobs.blank?
    return [nil, nil, AccountLimits::StorageUsageService::LIMIT_EXCEEDED_MESSAGE] unless storage_limit_available?(blobs, record)

    [blobs, sanitized, nil]
  end

  private

  def process_attachment_action(action, record, blobs)
    blob_id = action[:action_params].first
    blob = ActiveStorage::Blob.find_signed(blob_id.to_s)

    return action.merge(action_params: [blob.id]).tap { blobs << blob } if blob.present?
    return action if blob_already_attached?(record, blob_id)

    nil
  end

  def blob_already_attached?(record, blob_id)
    record&.files&.any? { |f| f.blob_id == blob_id.to_i }
  end

  def storage_limit_available?(blobs, record)
    account = record&.account || Current.account
    return true if account.blank?

    extra_bytes = blobs.sum(&:byte_size)
    AccountLimits::StorageUsageService.new(account: account).within_limit?(extra_bytes: extra_bytes)
  end
end
