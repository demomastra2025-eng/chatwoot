require 'rails_helper'

RSpec.describe WhatsappWeb::SendOnWhatsappWebService do
  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }
  let(:contact) { create(:contact, account: channel.account, name: 'Alice') }
  let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '15551234567') }
  let(:conversation) do
    create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end
  let(:message) do
    create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :sent
    )
  end

  it 'marks the message as failed for lid-only provisional recipients' do
    error = WhatsappWeb::Providers::EvolutionService::UnroutableRecipientError.new('Recipient is still provisional')
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    expect { described_class.new(message: message).perform }.not_to raise_error

    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to eq('Recipient is still provisional')
  end

  it 'marks the message as failed for permanent provider payload errors' do
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new('Bad Request', status: 400, body: {})
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    expect { described_class.new(message: message).perform }.not_to raise_error

    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to eq('Bad Request')
  end

  it 're-raises recoverable provider auth/session errors so Sidekiq can retry them' do
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new('Forbidden', status: 403, body: {})
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    expect { described_class.new(message: message).perform }.to raise_error(
      WhatsappWeb::Providers::EvolutionService::RequestError,
      'Forbidden'
    )
  end

  it 're-raises provider 5xx errors so Sidekiq can retry them' do
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new('Internal Error', status: 500, body: {})
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    expect { described_class.new(message: message).perform }.to raise_error(
      WhatsappWeb::Providers::EvolutionService::RequestError,
      'Internal Error'
    )
  end
end
