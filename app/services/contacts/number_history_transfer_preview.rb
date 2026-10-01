require 'digest'

# Read-only preview of a number transfer for the confirmation dialog and the dry-run report: exactly which chats would
# move from the previous holder to the card, what stays (other channels, unproven WhatsApp Web LID chats, chats of
# third contacts), and which relatives keep the number as доп. номер. The fingerprint lets the promote call detect
# that anything changed since the preview.
class Contacts::NumberHistoryTransferPreview
  def initialize(account:, phone:, card:, previous_holder:)
    @account = account
    @phone = phone
    @card = card
    @previous_holder = previous_holder
  end

  def moving_contact_inboxes
    return ContactInbox.none if @previous_holder.blank?

    @moving_contact_inboxes ||= Contacts::SharedPhone.identifying_contact_inboxes(
      account_id: @account.id, phone: @phone, owner_ids: [@previous_holder.id]
    ).order(:id).to_a
  end

  def conversations
    @conversations ||= Conversation.where(account_id: @account.id, contact_inbox_id: moving_contact_inboxes.map(&:id))
                                   .includes(:inbox).order(:id).to_a
  end

  # WhatsApp Web LID chats of the previous holder in an inbox where its phone-JID chat moves, but not provably tied to
  # it: they stay with the previous holder (and block the automatic promotion).
  def unproven_lid_contact_inboxes
    return [] if @previous_holder.blank?

    inbox_ids = moving_contact_inboxes.select { |ci| ci.inbox.channel_type == 'Channel::WhatsappWeb' }.map(&:inbox_id)
    return [] if inbox_ids.empty?

    ContactInbox.where(contact_id: @previous_holder.id, inbox_id: inbox_ids).where('source_id LIKE ?', '%@lid')
                .where.not(id: moving_contact_inboxes.map(&:id)).order(:id).to_a
  end

  def other_holder_ids
    Contacts::SharedPhone.identity_owner_ids(account_id: @account.id, phone: @phone, excluding: [@card.id, @previous_holder&.id])
  end

  def sibling_ids
    Contact.where(account_id: @account.id).where("custom_attributes -> 'secondary_phones' @> ?", [@phone].to_json)
           .where.not(id: [@card.id, @previous_holder&.id].compact).order(:id).pluck(:id)
  end

  def telephony_endpoint_count
    return 0 if @previous_holder.blank? || !ActiveRecord::Base.connection.data_source_exists?('telephony_contact_endpoints')

    ActiveRecord::Base.connection.select_values(
      Contacts::NumberHistoryTransferService.endpoint_ids_sql(contact_id: @previous_holder.id, phone: @phone)
    ).size
  end

  def message_counts
    @message_counts ||= Message.unscope(:order).where(conversation_id: conversations.map(&:id)).where.not(message_type: :activity)
                               .group(:conversation_id).count
  end

  def fingerprint
    Digest::SHA256.hexdigest([@account.id, @phone, @card.id, @previous_holder&.id, moving_contact_inboxes.map(&:id), other_holder_ids,
                              @card.phone_number.to_s].flatten.join(':'))
  end

  def as_json(*)
    counts_json.merge(
      fingerprint: fingerprint,
      previous_holder: contact_json(@previous_holder),
      conversations: conversations.map { |conversation| conversation_json(conversation) },
      not_moved_other_holders: Contact.where(id: other_holder_ids).map { |contact| contact_json(contact) },
      siblings: Contact.where(id: sibling_ids).map { |contact| contact_json(contact) }
    )
  end

  private

  def counts_json
    { contact_inboxes_count: moving_contact_inboxes.size, messages_count: message_counts.values.sum,
      telephony_endpoints_count: telephony_endpoint_count, not_moved_lid_chats_count: unproven_lid_contact_inboxes.size }
  end

  def conversation_json(conversation)
    { display_id: conversation.display_id, inbox_name: conversation.inbox&.name, messages_count: message_counts[conversation.id].to_i }
  end

  def contact_json(contact)
    return if contact.blank?

    { id: contact.id, name: contact.name }
  end
end
