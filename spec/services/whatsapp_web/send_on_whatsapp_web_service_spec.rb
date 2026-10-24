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
    expect(message.external_error).to eq('Не удалось определить номер получателя')
  end

  it 'marks the message as failed for permanent provider payload errors' do
    channel.update!(lifecycle_state: 'connected', connection_state: 'open')
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new('Bad Request', status: 400, body: {})
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    expect { described_class.new(message: message).perform }.not_to raise_error

    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to eq('Не удалось отправить сообщение в WhatsApp')
  end

  context 'when the recipient is a hidden @lid id' do
    let(:lid_jid) { '143907392331785@lid' }
    let(:lid_contact) do
      create(:contact, account: channel.account, additional_attributes: { 'lid_jid' => lid_jid, 'raw_jid' => lid_jid, 'canonical_jid' => lid_jid })
    end
    let(:lid_contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: lid_contact, source_id: lid_jid) }
    let(:lid_conversation) do
      create(:conversation, account: channel.account, inbox: channel.inbox, contact: lid_contact, contact_inbox: lid_contact_inbox)
    end
    let(:lid_message) { new_lid_message }
    let(:provider) { WhatsappWeb::Providers::EvolutionService.new(channel: channel) }
    let(:send_text_path) { "/message/sendText/#{channel.instance_name}" }

    def new_lid_message
      create(:message, account: channel.account, inbox: channel.inbox, conversation: lid_conversation, message_type: :outgoing, status: :sent)
    end

    def gateway_refuses(status, body: { 'status' => status, 'error' => 'Bad Request' })
      error = WhatsappWeb::Providers::EvolutionService::RequestError.new('Bad Request', status: status, body: body)
      allow(provider).to receive(:request).and_raise(error)
    end

    before do
      channel.update!(lifecycle_state: 'connected', connection_state: 'open')
      allow(channel).to receive(:provider_service).and_return(provider)
    end

    it 'sends the full @lid JID to the gateway' do
      expect(provider).to receive(:request)
        .with(:post, send_text_path, body: hash_including(number: lid_jid))
        .and_return({ 'key' => { 'id' => 'provider-message-id' } })

      described_class.new(message: lid_message).perform

      expect(lid_message.reload.source_id).to eq('provider-message-id')
    end

    it 'records an unroutable recipient when the gateway refuses it with a permanent 4xx' do
      [400, 404, 410, 422].each do |status|
        refused_message = new_lid_message
        gateway_refuses(status)

        expect { described_class.new(message: refused_message).perform }.not_to raise_error

        expect(refused_message.reload.status).to eq('failed')
        expect(refused_message.external_error).to eq('Не удалось определить номер получателя')
      end
    end

    it 'keeps the technical detail of the refusal in the log' do
      gateway_refuses(400, body: { 'status' => 400, 'response' => { 'message' => ['jid 143907392331785 does not exist'] } })
      allow(Rails.logger).to receive(:warn)

      described_class.new(message: lid_message).perform

      expect(Rails.logger).to have_received(:warn)
        .with(/Outbound message #{lid_message.id} failed.*LidRecipientRequestError status=400.*jid \[number\] does not exist/)
    end

    it 'is resent by the retry service once a phone identity arrives' do
      gateway_refuses(400)
      described_class.new(message: lid_message).perform
      clear_enqueued_jobs

      expect { WhatsappWeb::RetryFailedProvisionalMessagesService.new(channel: channel, contact: lid_contact).perform }
        .to have_enqueued_job(SendReplyJob).with(lid_message.id)
      expect(lid_message.reload.status).to eq('sent')
    end

    it 'blames the lost session when the refusal says that the connection is closed' do
      gateway_refuses(400, body: { 'response' => { 'message' => ['Error: Connection Closed'] } })

      described_class.new(message: lid_message).perform

      expect(lid_message.reload.external_error).to eq('WhatsApp отключён — переподключите номер в настройках канала')
    end

    it 'does not touch the retry of auth and transient errors' do
      [403, 500, 503].each do |status|
        pending_message = new_lid_message
        gateway_refuses(status)

        expect { described_class.new(message: pending_message).perform }
          .to raise_error(WhatsappWeb::Providers::EvolutionService::RequestError) { |error| expect(error.status).to eq(status) }
        expect(pending_message.reload.status).to eq('sent')
      end
    end

    it 'keeps the generic reason when the same refusal comes for a phone recipient' do
      gateway_refuses(400)

      described_class.new(message: message).perform

      expect(message.reload.external_error).to eq('Не удалось отправить сообщение в WhatsApp')
    end
  end

  it 'stores a reconnect hint instead of Bad Request when the gateway connection is closed' do
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new(
      'Error: Connection Closed',
      status: 400,
      body: { 'status' => 400, 'error' => 'Bad Request', 'response' => { 'message' => ['Error: Connection Closed'] } }
    )
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    described_class.new(message: message).perform

    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to eq('WhatsApp отключён — переподключите номер в настройках канала')
  end

  it 'explains an ambiguous failure by the lost session when the channel is disconnected' do
    channel.update!(lifecycle_state: 'disconnected', connection_state: 'close')
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new(
      'Bad Request',
      status: 404,
      body: { 'status' => 404, 'error' => 'Bad Request', 'message' => ['Group not found'] }
    )
    allow(channel).to receive(:send_message).with(message).and_raise(error)

    described_class.new(message: message).perform

    expect(message.reload.external_error).to eq('WhatsApp отключён — переподключите номер в настройках канала')
  end

  it 'stores a clear group message when the group is not found and keeps the technical detail in the log' do
    channel.update!(lifecycle_state: 'connected', connection_state: 'open')
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new(
      'Bad Request',
      status: 404,
      body: { 'status' => 404, 'error' => 'Bad Request', 'message' => ['Group not found'] }
    )
    allow(channel).to receive(:send_message).with(message).and_raise(error)
    allow(Rails.logger).to receive(:warn)

    described_class.new(message: message).perform

    expect(message.reload.external_error).to eq('Группа не найдена в WhatsApp (возможно, номер удалили из группы)')
    expect(Rails.logger).to have_received(:warn).with(/Outbound message #{message.id} failed.*status=404.*Group not found/)
  end

  it 'masks long digit runs in the logged detail' do
    error = WhatsappWeb::Providers::EvolutionService::RequestError.new(
      'Bad Request',
      status: 400,
      body: { 'response' => { 'message' => ['number 77012345678 is not on WhatsApp'] } }
    )
    allow(channel).to receive(:send_message).with(message).and_raise(error)
    allow(Rails.logger).to receive(:warn)

    described_class.new(message: message).perform

    expect(Rails.logger).to have_received(:warn).with(/\[number\] is not on WhatsApp/)
    expect(Rails.logger).not_to have_received(:warn).with(/77012345678/)
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
