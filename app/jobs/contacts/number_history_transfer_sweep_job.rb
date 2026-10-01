# Runs after a number transfer commits (and again two minutes later). An inbound webhook that loaded the previous
# holder before the transfer committed can still create a conversation or a contact message for it on a moved chat:
# ownership of the moved ContactInboxes is the source of truth, so those rows are re-pointed to the recipient. An
# identifying chat of the number that the previous holder gained meanwhile joins the transfer as an amendment, but only
# while the recipient still holds the number as its primary. Inert while ONELINK_SHARED_PHONE_HISTORY_TRANSFER is off.
class Contacts::NumberHistoryTransferSweepJob < ApplicationJob
  queue_as :medium

  def perform(account_id, contact_id, transfer_id)
    return unless Contacts::NumberHistoryTransferService.enabled?

    to = Contact.find_by(id: contact_id, account_id: account_id)
    entry = to && Contacts::NumberHistoryTransferService.find_entry(to, transfer_id)
    return if entry.blank? || entry['reverted_at'].present?

    from = Contact.find_by(id: entry['counterpart_contact_id'], account_id: account_id)
    sweep_moved_chats!(to, from, entry)
    amend_new_identities!(to, from, entry) if from
  end

  private

  def sweep_moved_chats!(to, from, entry)
    ActiveRecord::Base.transaction do
      Contacts::PhoneIdentityLock.acquire!(account_id: to.account_id)
      ci_ids = ContactInbox.where(id: Array(entry['contact_inbox_ids']), contact_id: to.id).pluck(:id)
      stale = repoint_stale_conversations!(to, ci_ids)
      repoint_stale_messages!(to, from, ci_ids) if from
      Conversation.where(id: stale).find_each(&:refresh_communication_thread!)
    end
  end

  # rubocop:disable Rails/SkipsModelValidations
  def repoint_stale_conversations!(to, ci_ids)
    stale = Conversation.where(contact_inbox_id: ci_ids).where.not(contact_id: to.id).order(:id).lock('FOR NO KEY UPDATE').pluck(:id)
    Conversation.where(id: stale).update_all(contact_id: to.id, updated_at: Time.current) if stale.any?
    stale
  end

  def repoint_stale_messages!(to, from, ci_ids)
    Message.where(conversation_id: Conversation.where(contact_inbox_id: ci_ids).select(:id), sender_type: 'Contact', sender_id: from.id)
           .update_all(sender_id: to.id, updated_at: Time.current)
  end
  # rubocop:enable Rails/SkipsModelValidations

  def amend_new_identities!(to, from, entry)
    return unless Contacts::NumberHistoryTransferService.recipient_holds_number?(to.reload, entry['phone'])

    leftover = Contacts::SharedPhone.identifying_contact_inboxes(account_id: to.account_id, phone: entry['phone'], owner_ids: [from.id]).pluck(:id)
    return if leftover.empty?

    Contacts::NumberHistoryTransferService.new(account: to.account, phone: entry['phone'], from: from, to: to, basis: entry['basis'],
                                               contact_inbox_ids: leftover, amendment_of: entry['id']).perform!
  end
end
