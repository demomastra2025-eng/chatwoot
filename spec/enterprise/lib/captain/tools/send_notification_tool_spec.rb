require 'rails_helper'

RSpec.describe Captain::Tools::SendNotificationTool, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:recipient) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:tool) { described_class.new(assistant) }
  let(:tool_context) { Struct.new(:state).new({ conversation: { id: conversation.id } }) }

  it 'creates a native in-app notification for the selected account user' do
    payload = JSON.parse(tool.perform(
                           tool_context,
                           title: 'Need manager approval',
                           message: 'Please review this customer request',
                           recipient_id: recipient.id
                         ))

    notification = Notification.find(payload.dig('notification', 'id'))
    expect(payload).to include('action' => 'send_notification')
    expect(payload.dig('notification', 'title')).to eq('Need manager approval')
    expect(payload.dig('notification', 'message')).to eq('Please review this customer request')
    expect(notification).to have_attributes(
      notification_type: 'captain_notification',
      account: account,
      user: recipient,
      primary_actor: conversation
    )
    expect(notification.push_message_title).to eq('Need manager approval')
    expect(notification.push_message_body).to eq('Please review this customer request')
  end

  it 'rejects ambiguous recipient selectors instead of guessing' do
    result = tool.perform(
      tool_context,
      title: 'Need manager approval',
      message: 'Please review this customer request',
      recipient_id: recipient.id,
      recipient_email: recipient.email
    )

    expect(result).to include('Exactly one recipient selector is required')
    expect(Notification.captain_notification.count).to eq(0)
  end
end
