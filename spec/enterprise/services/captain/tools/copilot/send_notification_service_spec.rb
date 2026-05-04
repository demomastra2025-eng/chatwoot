require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SendNotificationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:recipient) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  it 'returns a normalized notification payload wrapper' do
    payload = JSON.parse(service.execute(
                           title: 'Captain escalation',
                           message: 'Customer needs a callback today',
                           recipient_email: recipient.email
                         ))

    notification = Notification.find(payload.dig('notification', 'id'))
    expect(payload['action']).to eq('send_notification')
    expect(payload.dig('notification', 'recipient', 'id')).to eq(recipient.id)
    expect(payload.dig('notification', 'conversation_display_id')).to eq(conversation.display_id)
    expect(notification).to have_attributes(
      notification_type: 'captain_notification',
      user: recipient,
      primary_actor: conversation,
      secondary_actor: user
    )
    expect(notification.meta.dig('captain_notification', 'actor_user_id')).to eq(user.id)
  end

  it 'uses the provided conversation_id when there is no active conversation' do
    service_without_conversation = described_class.new(assistant, user: user, conversation: nil)

    payload = JSON.parse(service_without_conversation.execute(
                           message: 'Please check this conversation',
                           recipient_id: recipient.id,
                           conversation_id: conversation.display_id
                         ))

    expect(payload.dig('notification', 'conversation_id')).to eq(conversation.id)
  end
end
