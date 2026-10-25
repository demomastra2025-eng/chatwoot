# Removes the chats of Telegram's service account that were taken in before it was skipped
# (onelink:telegram_personal:purge_service_account_chats).
#
# Until TelegramPersonal::ServiceAccount was in place, the login codes and the notices of new sign-ins (device, place) that
# Telegram writes as user 777000 were imported into the personal inboxes like any chat, and every agent of the inbox can read and
# search them. This finds, in the Telegram personal inboxes, the contact inboxes whose source id is a service account
# (TelegramPersonal::ServiceAccount.user_ids: 777000, and 42777 on the test servers). A dry run (the default) only counts;
# `apply: true` deletes their messages, their conversations and the contact inbox, and the contact when nothing else is left of it
# (another inbox, another conversation). A group is never touched: its contact inbox has the id of the group.
#
# The report counts per inbox and never carries a text.
#
#   report = TelegramPersonal::ServiceAccountPurge.new(apply: false).perform
#   report.inboxes # => { 99 => { account_id: 1, contact_inboxes: 1, conversations: 1, messages: 19, contacts: 1 } }
class TelegramPersonal::ServiceAccountPurge
  Report = Struct.new(:apply, :inboxes, keyword_init: true) do
    def total(key)
      inboxes.values.sum { |counts| counts[key] }
    end
  end

  def initialize(apply: false, inbox_ids: nil)
    @apply = apply
    @inbox_ids = Array(inbox_ids).compact_blank.map(&:to_i).presence
  end

  def perform
    @report = Report.new(apply: @apply, inboxes: {})
    contact_inboxes.find_each { |contact_inbox| purge(contact_inbox) }
    @report
  end

  private

  def contact_inboxes
    scope = ContactInbox.joins(:inbox)
                        .where(inboxes: { channel_type: 'Channel::TelegramPersonal' })
                        .where(source_id: TelegramPersonal::ServiceAccount.user_ids)
                        .includes(:inbox, :contact)
    @inbox_ids ? scope.where(inbox_id: @inbox_ids) : scope
  end

  def purge(contact_inbox)
    conversations = contact_inbox.conversations.to_a
    contact = contact_inbox.contact
    removable_contact = contact.present? && removable_contact?(contact, contact_inbox)
    count(contact_inbox, conversations, removable_contact)
    return unless @apply

    ActiveRecord::Base.transaction do
      conversations.each do |conversation|
        conversation.messages.destroy_all
        conversation.destroy!
      end
      contact_inbox.destroy!
      contact.reload.destroy! if removable_contact
    end
  end

  # The contact goes with the chat only when it has no other inbox, no other conversation and no message anywhere else
  def removable_contact?(contact, contact_inbox)
    contact.contact_inboxes.where.not(id: contact_inbox.id).none? &&
      contact.conversations.where.not(contact_inbox_id: contact_inbox.id).none? &&
      Message.where(sender: contact).where.not(conversation_id: contact_inbox.conversations.select(:id)).none?
  end

  def count(contact_inbox, conversations, removable_contact)
    counts = @report.inboxes[contact_inbox.inbox_id] ||=
      { account_id: contact_inbox.inbox.account_id, contact_inboxes: 0, conversations: 0, messages: 0, contacts: 0 }
    counts[:contact_inboxes] += 1
    counts[:conversations] += conversations.size
    counts[:messages] += Message.where(conversation_id: conversations.map(&:id)).count
    counts[:contacts] += 1 if removable_contact
  end
end
