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

  def newer_customer_incoming_message
    Message.unscoped
           .where(
             account_id: trigger_message.account_id,
             conversation_id: trigger_message.conversation_id,
             message_type: Message.message_types[:incoming],
             private: false,
             sender_type: 'Contact'
           )
           .where('id > ?', trigger_message.id)
           .order(id: :desc)
           .first
  end
end
