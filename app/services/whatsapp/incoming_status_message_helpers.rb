module Whatsapp::IncomingStatusMessageHelpers
  def processed_waid(waid)
    source_id = Whatsapp::ContactIdentityResolver.phone_source_id(waid)
    return if source_id.blank?

    Whatsapp::PhoneNumberNormalizationService.new(inbox).normalize_and_find_contact_by_provider(source_id, :cloud)
  end

  def update_whatsapp_identifiers_from_status(status)
    contact_inbox = @message&.conversation&.contact_inbox
    return if contact_inbox.blank?

    Whatsapp::IdentifierSyncService.new(contact_inbox: contact_inbox, contact: contact_inbox.contact).perform(
      source_ids: status_source_ids(status),
      phone_number: status_phone_number(status)
    )
  end

  def error_webhook_event?(message)
    return false if unsupported_whatsapp_message?(message)

    message.key?('errors')
  end

  def log_error(message)
    Rails.logger.warn "Whatsapp Error: #{message['errors'][0]['title']} - contact: #{message['from']}"
  end

  private

  def status_source_ids(status)
    contact_params = @processed_params[:contacts]&.first || {}

    [
      status_phone_source_id(status),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(status[:recipient_user_id]),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(status[:recipient_parent_user_id]),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(contact_params[:user_id]),
      Whatsapp::ContactIdentityResolver.bsuid_source_id(contact_params[:parent_user_id])
    ].compact_blank.uniq
  end

  def status_phone_number(status)
    Whatsapp::ContactIdentityResolver.phone_number_for(status_phone_source_id(status))
  end

  def status_phone_source_id(status)
    contact_params = @processed_params[:contacts]&.first || {}

    processed_waid(contact_params[:wa_id].presence || status[:recipient_id])
  end
end
