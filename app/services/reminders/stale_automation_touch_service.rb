# frozen_string_literal: true

class Reminders::StaleAutomationTouchService
  attr_reader :reminder, :trigger_message

  def initialize(reminder:, trigger_message:)
    @reminder = reminder
    @trigger_message = trigger_message
  end

  def perform
    return false if trigger_message.blank?

    newer_message = newer_customer_incoming_message
    return false if newer_message.blank?

    Reminders::IncomingReplyCancellationService.new(
      reminder: reminder,
      message: newer_message
    ).perform
  end

  private

  # The person answers in any of their channels, like in Reminders::AutoCancelOnIncomingService: besides the trigger
  # conversation (every message of a contact counts there, as before), a reply of its owner in another of their
  # conversations makes the touch stale too. Imported history is old chat, not a reply.
  def newer_customer_incoming_message
    newer = customer_incoming_messages_after_trigger
    in_trigger_conversation = newer.where(conversation_id: trigger_message.conversation_id)
    return in_trigger_conversation.first if owner_contact_id.blank?

    in_trigger_conversation.or(newer_in_other_conversations(newer)).first
  end

  def customer_incoming_messages_after_trigger
    Message.unscoped
           .where(
             account_id: trigger_message.account_id,
             message_type: Message.message_types[:incoming],
             private: false,
             sender_type: 'Contact'
           )
           .where('id > ?', trigger_message.id)
           .order(id: :desc)
  end

  def newer_in_other_conversations(newer)
    person_conversations = Conversation.where(account_id: trigger_message.account_id, contact_id: owner_contact_id)
    newer.where(sender_id: owner_contact_id, conversation_id: person_conversations.select(:id))
         .where(Message.not_imported_history_sql)
  end

  def owner_contact_id
    trigger_message.conversation.contact_id
  end
end
