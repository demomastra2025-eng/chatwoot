require 'rails_helper'

RSpec.describe 'Webhooks::TelegramController', type: :request do
  let!(:telegram_channel) { create(:channel_telegram) }

  describe 'POST /webhooks/telegram/:bot_token' do
    it 'returns 404 and does not enqueue job for unknown bot_token' do
      expect(Webhooks::TelegramEventsJob).not_to receive(:perform_later)

      post '/webhooks/telegram/unknown_random_bot_token', params: { content: 'hello' }

      expect(response).to have_http_status(:not_found)
    end

    it 'enqueues TelegramEventsJob with channel_id and strips plaintext bot_token when valid secret header is provided' do
      expect(Webhooks::TelegramEventsJob).to receive(:perform_later).with(
        satisfy { |arg| arg['channel_id'] == telegram_channel.id && !arg.key?('bot_token') && !arg.key?(:bot_token) }
      )

      post "/webhooks/telegram/#{telegram_channel.bot_token}",
           params: { content: 'hello' },
           headers: { 'X-Telegram-Bot-Api-Secret-Token' => telegram_channel.webhook_secret_token }

      expect(response).to have_http_status(:ok)
    end

    it 'rejects forged or whitespace-only X-Telegram-Bot-Api-Secret-Token with 401' do
      expect(Webhooks::TelegramEventsJob).not_to receive(:perform_later)

      post "/webhooks/telegram/#{telegram_channel.bot_token}",
           params: { content: 'hello' },
           headers: { 'X-Telegram-Bot-Api-Secret-Token' => 'forged-secret-token' }
      expect(response).to have_http_status(:unauthorized)

      post "/webhooks/telegram/#{telegram_channel.bot_token}",
           params: { content: 'hello' },
           headers: { 'X-Telegram-Bot-Api-Secret-Token' => '   ' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'preserves backward compatibility for legacy webhooks without secret header unless strict mode is enabled' do
      with_modified_env TELEGRAM_WEBHOOK_REQUIRE_SECRET_TOKEN: 'false' do
        expect(Webhooks::TelegramEventsJob).to receive(:perform_later)

        post "/webhooks/telegram/#{telegram_channel.bot_token}", params: { content: 'hello' }

        expect(response).to have_http_status(:ok)
      end

      with_modified_env TELEGRAM_WEBHOOK_REQUIRE_SECRET_TOKEN: 'true' do
        expect(Webhooks::TelegramEventsJob).not_to receive(:perform_later)

        post "/webhooks/telegram/#{telegram_channel.bot_token}", params: { content: 'hello' }

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
