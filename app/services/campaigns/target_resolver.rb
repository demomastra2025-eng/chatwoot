class Campaigns::TargetResolver
  pattr_initialize [:inbox!, :contact!]

  def resolve
    matching_contactable_inbox&.dig(:source_id).presence
  end

  private

  def matching_contactable_inbox
    @matching_contactable_inbox ||= contactable_inboxes.find { |entry| entry[:inbox].id == inbox.id }
  end

  def contactable_inboxes
    @contactable_inboxes ||= Contacts::ContactableInboxesService.new(contact: contact).get
  end
end
