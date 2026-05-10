# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Telegram notification webhook', type: :request do
  let(:webhook_secret) { 'telegram-notification-secret' }
  let(:headers) { { 'Content-Type' => 'application/json' } }
  let(:user) { create(:user) }
  let(:telegram_message) do
    {
      message: {
        text: user.access_token.token,
        from: {
          id: 12_345,
          username: 'telegram_agent',
          first_name: 'Telegram',
          last_name: 'Agent'
        },
        chat: { id: 67_890 }
      }
    }
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('TELEGRAM_NOTIFICATION_WEBHOOK_SECRET', nil).and_return(webhook_secret)
    allow(TelegramNotification::BotClient).to receive(:send_message)
  end

  it 'links telegram to the user matching the profile access token' do
    post "/webhooks/telegram_notifications/#{webhook_secret}", params: telegram_message.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    binding = user.reload.telegram_notification_binding
    expect(binding).to be_connected
    expect(binding.telegram_user_id).to eq('12345')
    expect(binding.telegram_chat_id).to eq('67890')
    expect(TelegramNotification::BotClient).to have_received(:send_message).with(
      chat_id: 67_890,
      text: include('Готово')
    )
  end

  it 'accepts /start payload with the profile access token' do
    telegram_message[:message][:text] = "/start #{user.access_token.token}"

    post "/webhooks/telegram_notifications/#{webhook_secret}", params: telegram_message.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(user.reload.telegram_notification_binding).to be_connected
  end

  it 'rejects unknown profile access tokens' do
    telegram_message[:message][:text] = 'missing-token'

    post "/webhooks/telegram_notifications/#{webhook_secret}", params: telegram_message.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(user.reload.telegram_notification_binding).to be_nil
    expect(TelegramNotification::BotClient).to have_received(:send_message).with(
      chat_id: 67_890,
      text: include('Токен доступа не найден')
    )
  end

  it 'returns not found for invalid webhook secrets' do
    post '/webhooks/telegram_notifications/wrong-secret', params: telegram_message.to_json, headers: headers

    expect(response).to have_http_status(:not_found)
    expect(user.reload.telegram_notification_binding).to be_nil
  end
end
