require 'rails_helper'

RSpec.describe Webhooks::TelegramEventsJob do
  subject(:job) { described_class.perform_later(params) }

  let!(:telegram_channel) { create(:channel_telegram) }
  let!(:params) { { :bot_token => telegram_channel.bot_token, 'telegram' => { test: 'test' } } }

  it 'enqueues the job' do
    expect { job }.to have_enqueued_job(described_class)
      .with(params)
      .on_queue('telegram_inbound')
  end

  context 'when invalid params' do
    it 'returns nil when no bot_token' do
      expect(described_class.perform_now({})).to be_nil
    end

    it 'logs a redacted warning without leaking bot_token when channel is not found' do
      expect(Rails.logger).to receive(:warn).with('Telegram event discarded: Channel not found for bot_token: [REDACTED]')
      described_class.perform_now({ bot_token: 'invalid-secret-token' })
    end
  end

  context 'when valid params' do
    it 'resolves channel by channel_id without requiring bot_token in Redis payload' do
      process_service = instance_double(Telegram::IncomingMessageService, perform: true)
      expect(Telegram::IncomingMessageService).to receive(:new)
        .with(inbox: telegram_channel.inbox, params: params['telegram'].with_indifferent_access)
        .and_return(process_service)

      described_class.perform_now({ 'channel_id' => telegram_channel.id, 'telegram' => { test: 'test' } }.with_indifferent_access)
    end

    it 'calls Telegram::IncomingMessageService' do
      process_service = double
      allow(Telegram::IncomingMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)
      expect(Telegram::IncomingMessageService).to receive(:new).with(inbox: telegram_channel.inbox,
                                                                     params: params['telegram'].with_indifferent_access)
      expect(process_service).to receive(:perform)
      described_class.perform_now(params.with_indifferent_access)
    end

    it 'logs a warning and does not process events if account is suspended' do
      account = telegram_channel.account
      account.update!(status: :suspended)

      process_service = double
      allow(Telegram::IncomingMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)

      expect(Rails.logger).to receive(:warn).with("Telegram event discarded: Account #{account.id} is not active for channel #{telegram_channel.id}")
      expect(Telegram::IncomingMessageService).not_to receive(:new)
      described_class.perform_now(params.with_indifferent_access)
    end
  end

  context 'when update message params' do
    let!(:params) { { :bot_token => telegram_channel.bot_token, 'telegram' => { edited_message: 'test' } } }

    it 'calls Telegram::UpdateMessageService' do
      process_service = double
      allow(Telegram::UpdateMessageService).to receive(:new).and_return(process_service)
      allow(process_service).to receive(:perform)
      expect(Telegram::UpdateMessageService).to receive(:new).with(inbox: telegram_channel.inbox,
                                                                   params: params['telegram'].with_indifferent_access)
      expect(process_service).to receive(:perform)
      described_class.perform_now(params.with_indifferent_access)
    end
  end
end
