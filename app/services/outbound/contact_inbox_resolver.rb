class Outbound::ContactInboxResolver
  pattr_initialize [:inbox!, :contact!, { source_id: nil }]

  def perform
    return if resolved_source_id.blank?

    matching_contact_inbox || latest_contact_inbox || create_contact_inbox
  end

  private

  def resolved_source_id
    @resolved_source_id ||= source_id.presence || Campaigns::TargetResolver.new(inbox: inbox, contact: contact).resolve
  end

  def matching_contact_inbox
    inbox.contact_inboxes.find_by(contact: contact, source_id: resolved_source_id)
  end

  def latest_contact_inbox
    return if source_id.present?

    inbox.contact_inboxes.where(contact: contact).order(created_at: :desc).first
  end

  def create_contact_inbox
    ContactInboxBuilder.new(contact: contact, inbox: inbox, source_id: resolved_source_id).perform
  end
end
