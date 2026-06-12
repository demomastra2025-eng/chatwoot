class Whatsapp::PreferredContactInboxResolver
  pattr_initialize [:contact!, :inbox!, :fallback_contact_inbox]

  def perform
    phone_contact_inbox || valid_fallback_contact_inbox
  end

  private

  def phone_contact_inbox
    contact_inboxes.detect do |contact_inbox|
      Whatsapp::ContactIdentityResolver.phone_source_id(contact_inbox.source_id).present?
    end
  end

  def valid_fallback_contact_inbox
    return if fallback_contact_inbox.blank?
    return unless fallback_contact_inbox.contact_id == contact.id
    return unless fallback_contact_inbox.inbox_id == inbox.id
    return if Whatsapp::ContactIdentityResolver.phone_source_id(fallback_contact_inbox.source_id).blank?

    fallback_contact_inbox
  end

  def contact_inboxes
    @contact_inboxes ||= contact.contact_inboxes.where(inbox_id: inbox.id).order(:id).to_a
  end
end
