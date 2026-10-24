require 'rails_helper'

RSpec.describe Notification::TelegramNotificationService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:notification) do
    create(:notification, user: user, account: account, primary_actor: conversation, notification_type: :conversation_assignment)
  end

  before do
    create(:telegram_notification_binding, :connected, user: user, telegram_chat_id: '12345')
    setting = user.notification_settings.find_by(account_id: account.id)
    setting.selected_telegram_flags = [:telegram_conversation_assignment]
    setting.save!

    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('TELEGRAM_NOTIFICATION_BOT_TOKEN', nil).and_return('test-token')
    allow(TelegramNotification::BotClient).to receive(:send_message)
  end

  it 'sends telegram notification to connected binding' do
    described_class.new(notification: notification).perform

    expect(TelegramNotification::BotClient).to have_received(:send_message).with(
      chat_id: '12345',
      text: a_string_including(notification.push_message_title)
    )
  end

  it 'links to the conversation when the account does not use communication threads' do
    described_class.new(notification: notification).perform

    expect(TelegramNotification::BotClient).to have_received(:send_message).with(
      chat_id: '12345',
      text: a_string_including("/app/accounts/#{account.id}/conversations/#{conversation.display_id}")
    )
  end

  it 'links to the dialog of the person when the account uses communication threads' do
    account.enable_features!('communication_threads')
    thread = conversation.reload.communication_thread

    described_class.new(notification: notification).perform

    expect(TelegramNotification::BotClient).to have_received(:send_message).with(
      chat_id: '12345',
      text: a_string_including("/app/accounts/#{account.id}/communication_threads/#{thread.display_id}")
    )
  end
end
