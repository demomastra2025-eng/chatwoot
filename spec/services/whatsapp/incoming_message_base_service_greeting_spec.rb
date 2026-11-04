require 'rails_helper'

RSpec.describe Whatsapp::IncomingMessageBaseService do
  let(:encoded) { 'Здравствуйте,%20я%20с%20Instagram' }
  let(:plain) { 'Здравствуйте, я с Instagram' }

  shared_examples 'a WhatsApp greeting ingress' do
    it 'normalizes the known greeting and retains the original alongside existing attributes' do
      original = ingest('Original synthetic message')
      message = ingest(encoded, reply_to: original.source_id)

      expect(message.content).to eq(plain)
      expect(message.content_attributes).to include(
        'whatsapp_original_encoded_text' => encoded,
        'whatsapp_message_type' => 'text'
      )
      expect(message.content_attributes['in_reply_to_external_id']).to eq(original.source_id)
      expect(message.content_attributes['in_reply_to']).to eq(original.id)
    end

    it 'is idempotent through ingress and leaves the provider payload untouched' do
      first = ingest(encoded)
      second = ingest(first.content)

      expect(first.content).to eq(plain)
      expect(second.content).to eq(plain)
      expect(second.content_attributes).not_to have_key('whatsapp_original_encoded_text')
    end

    it 'only decodes the recognized prefix before appended text and URLs' do
      suffix = '%20Сәлем 👋 + 20% %0A %25 https://example.test/a%20b?q=x%20y'
      message = ingest(encoded + suffix)

      expect(message.content).to eq(plain + suffix)
      expect(message.content_attributes['whatsapp_original_encoded_text']).to eq(encoded + suffix)
    end

    [
      'Здравствуйте, я с Instagram',
      'Скидка 20% + 5% — Сәлем 👋',
      'https://example.test/a%20b?q=x%20y',
      'Здравствуйте,%20я%20с%20instagram',
      'Здравствуйте,%20я%20с%20Instagrammer',
      'Привет%20из%20Instagram — Сәлем 👋',
      'https://example.test/Здравствуйте,%20я%20с%20Instagram',
      'Здравствуйте,%2520я%2520с%2520Instagram',
      'Здравствуйте,+я+с+Instagram',
      'Здравствуйте,%0Aя%20с%20Instagram'
    ].each do |text|
      it "preserves unrecognized or plain text #{text.inspect}" do
        message = ingest(text)

        expect(message.content).to eq(text)
        expect(message.content_attributes).not_to have_key('whatsapp_original_encoded_text')
      end
    end

    it 'normalizes mixed plain and encoded spaces in the known greeting' do
      message = ingest('Здравствуйте, я%20с Instagram. Сәлем 👋')

      expect(message.content).to eq('Здравствуйте, я с Instagram. Сәлем 👋')
      expect(message.content_attributes['whatsapp_original_encoded_text']).to eq('Здравствуйте, я%20с Instagram. Сәлем 👋')
    end

    it 'leaves outgoing echoes unchanged' do
      message = ingest(encoded, outgoing: true)

      expect(message).to be_outgoing
      expect(message.content).to eq(encoded)
      expect(message.content_attributes).not_to have_key('whatsapp_original_encoded_text')
    end
  end

  context 'with the Meta-compatible incoming message service' do
    let(:channel) { create(:channel_whatsapp, sync_templates: false) }

    before { stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook') }

    def ingest(text, outgoing: false, reply_to: 'original-source')
      source = SecureRandom.uuid
      message = {
        id: source, type: 'text', from: '15551234567', to: '15551234567',
        text: { body: text }, context: { id: reply_to }
      }
      payload = {
        contacts: [{ wa_id: '15551234567', profile: { name: 'Synthetic sender' } }], messages: [message]
      }.with_indifferent_access
      original = payload.deep_dup
      Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: payload, outgoing_echo: outgoing).perform
      expect(payload).to eq(original)
      channel.inbox.messages.find_by!(source_id: source)
    end

    it_behaves_like 'a WhatsApp greeting ingress'

    it 'does not normalize button text or its payload' do
      payload = {
        contacts: [{ wa_id: '15551234567', profile: { name: 'Synthetic sender' } }],
        messages: [{ id: 'button-greeting', from: '15551234567', type: 'button', button: { text: encoded, payload: 'literal%20value' } }]
      }.with_indifferent_access
      Whatsapp::IncomingMessageService.new(inbox: channel.inbox, params: payload).perform

      message = channel.inbox.messages.find_by!(source_id: 'button-greeting')
      expect(message.content).to eq(encoded)
      expect(message.content_attributes['button_payload']).to eq('literal%20value')
      expect(message.content_attributes).not_to have_key('whatsapp_original_encoded_text')
    end

    it 'normalizes the Cloud API envelope through the same base ingress' do
      value = {
        contacts: [{ wa_id: '15551234567', profile: { name: 'Synthetic sender' } }],
        messages: [{ id: 'cloud-greeting', from: '15551234567', type: 'text', text: { body: encoded } }]
      }
      payload = { entry: [{ changes: [{ value: value }] }] }.with_indifferent_access
      Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: channel.inbox, params: payload).perform

      message = channel.inbox.messages.find_by!(source_id: 'cloud-greeting')
      expect(message.content).to eq(plain)
      expect(message.content_attributes['whatsapp_original_encoded_text']).to eq(encoded)
    end
  end

  context 'with Evolution WhatsApp Web events' do
    let(:channel) { create(:channel_whatsapp_web) }

    def ingest(text, outgoing: false, reply_to: 'original-source')
      source = SecureRandom.uuid
      data = {
        key: { id: source, remoteJid: '15551234567@s.whatsapp.net', fromMe: outgoing },
        pushName: 'Synthetic sender',
        message: { extendedTextMessage: { text: text, contextInfo: { stanzaId: reply_to } } }
      }.with_indifferent_access
      original = data.deep_dup
      if outgoing
        WhatsappWeb::IncomingMessageService.new(inbox: channel.inbox, params: data, outgoing_echo: true).perform
      else
        WhatsappWeb::IncomingEventService.new(
          channel: channel, payload: { event: 'messages.upsert', data: data }.with_indifferent_access
        ).perform
      end
      expect(data).to eq(original)
      channel.inbox.messages.find_by!(source_id: source)
    end

    it_behaves_like 'a WhatsApp greeting ingress'

    it 'also normalizes Evolution conversation text' do
      WhatsappWeb::IncomingEventService.new(
        channel: channel,
        payload: {
          event: 'messages.upsert',
          data: {
            key: { id: 'conversation-greeting', remoteJid: '15551234567@s.whatsapp.net', fromMe: false },
            message: { conversation: encoded }
          }
        }.with_indifferent_access
      ).perform

      message = channel.inbox.messages.find_by!(source_id: 'conversation-greeting')
      expect(message.content).to eq(plain)
      expect(message.content_attributes['whatsapp_original_encoded_text']).to eq(encoded)
    end
  end

  it 'does not normalize messages from other channels' do
    message = create(:message, content: encoded)

    expect(message.reload.content).to eq(encoded)
    expect(message.content_attributes).not_to have_key('whatsapp_original_encoded_text')
  end
end
