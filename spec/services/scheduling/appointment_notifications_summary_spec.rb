require 'rails_helper'

RSpec.describe Scheduling::AppointmentNotificationsSummary do
  it 'includes the rule and materialized message delivery state for an appointment' do
    account = create(:account)
    appointment = create(:scheduling_appointment, account: account)
    rule = create(:automation_rule, account: account, name: 'Appointment reminder')
    conversation = create(:conversation, account: account)
    message = create(:message, account: account, conversation: conversation, status: :delivered)
    reminder = create(:reminder, account: account, remindable: appointment, conversation: conversation)
    reminder.mark_automation_provenance!(rule)
    reminder.mark_delivery_materialized!(message.id)

    item = described_class.new(account: account, appointment: appointment).perform.find { |result| result[:id] == reminder.id }

    expect(item).to include(
      rule_name: 'Appointment reminder', message_id: message.id,
      conversation_id: conversation.id, message_status: 'delivered'
    )
  end
end
