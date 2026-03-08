require 'rails_helper'

RSpec.describe Integrations::Macrocrm::ProcessorService do
  subject(:perform) { described_class.new(hook: hook, event_name: event_name, message: message).perform }

  let(:event_name) { 'message.created' }
  let(:account) { create(:account) }
  let(:whatsapp_channel) do
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:contact) { create(:contact, account: account, name: 'Ahan', phone_number: '+77001234567') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77001234567') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:message) do
    create(:message,
           account: account,
           inbox: inbox,
           conversation: conversation,
           message_type: 'incoming',
           content: 'Здравствуйте, хочу узнать о квартирах')
  end
  let(:hook) do
    create(:integrations_hook,
           account: account,
           app_id: 'macrocrm',
           access_token: 'macro-secret',
           settings: {
             'app_id' => 'macro-app',
             'sync_incoming_messages' => true,
             'sync_outgoing_messages' => true
           })
  end
  let(:client) { instance_double(Integrations::Macrocrm::Client) }

  before do
    allow(Integrations::Macrocrm::Client).to receive(:new).with(hook: hook).and_return(client)
  end

  context 'when the contact and a deal already exist' do
    it 'adds the message as a note to the last deal' do
      allow(client).to receive(:find_contact).with(phone: '+77001234567').and_return(
        { 'contact' => { 'id' => 5044369, 'name' => 'Аманжол' } }
      )
      allow(client).to receive(:find_estate_buy).with(contact_id: 5044369).and_return(
        { 'buys' => [{ 'id' => 5767119 }] }
      )
      allow(client).to receive(:create_estate_buy)
      allow(client).to receive(:add_note)

      perform

      expect(client).not_to have_received(:create_estate_buy)
      expect(client).to have_received(:add_note).with(
        estate_id: 5767119,
        note: '[Входящее WhatsApp] Здравствуйте, хочу узнать о квартирах'
      )
    end
  end

  context 'when the contact exists but does not have a deal' do
    it 'creates a deal before adding the note' do
      allow(client).to receive(:find_contact).with(phone: '+77001234567').and_return(
        { 'contact' => { 'id' => 5044369, 'name' => 'Аманжол' } }
      )
      allow(client).to receive(:find_estate_buy).with(contact_id: 5044369).and_return(
        { 'buys' => [] }
      )
      allow(client).to receive(:create_estate_buy).with(
        name: 'Аманжол',
        phone: '+77001234567',
        message: 'Здравствуйте, хочу узнать о квартирах'
      ).and_return({ 'estate' => { 'id' => 4321 } })
      allow(client).to receive(:add_note)

      perform

      expect(client).to have_received(:add_note).with(
        estate_id: 4321,
        note: '[Входящее WhatsApp] Здравствуйте, хочу узнать о квартирах'
      )
    end
  end

  context 'when the contact is not found in macrocrm' do
    it 'creates both the deal and the note from the whatsapp message' do
      allow(client).to receive(:find_contact).with(phone: '+77001234567').and_return(
        { 'contact' => nil }
      )
      allow(client).to receive(:create_estate_buy).with(
        name: 'Ahan',
        phone: '+77001234567',
        message: 'Здравствуйте, хочу узнать о квартирах'
      ).and_return({ 'estate' => { 'id' => 4321 } })
      allow(client).to receive(:add_note)

      perform

      expect(client).to have_received(:add_note).with(
        estate_id: 4321,
        note: '[Входящее WhatsApp] Здравствуйте, хочу узнать о квартирах'
      )
    end
  end

  context 'when outgoing sync is disabled' do
    let(:message) do
      create(:message,
             account: account,
             inbox: inbox,
             conversation: conversation,
             message_type: 'outgoing',
             content: 'Добрый день! Какие квартиры интересуют?')
    end
    let(:hook) do
      create(:integrations_hook,
             account: account,
             app_id: 'macrocrm',
             access_token: 'macro-secret',
             settings: {
               'app_id' => 'macro-app',
               'sync_incoming_messages' => true,
               'sync_outgoing_messages' => false
             })
    end

    before do
      allow(message).to receive(:outgoing_content).and_return('Добрый день! Какие квартиры интересуют?')
      allow(client).to receive(:find_contact)
    end

    it 'skips the sync entirely' do
      perform

      expect(client).not_to have_received(:find_contact)
    end
  end

  context 'when the contact phone is missing on the contact record' do
    let(:contact) { create(:contact, account: account, name: 'Ahan', phone_number: nil) }

    it 'falls back to the whatsapp source id and normalizes it to e164' do
      allow(client).to receive(:find_contact).with(phone: '+77001234567').and_return(
        { 'contact' => nil }
      )
      allow(client).to receive(:create_estate_buy).and_return({ 'estate' => { 'id' => 4321 } })
      allow(client).to receive(:add_note)

      perform

      expect(client).to have_received(:find_contact).with(phone: '+77001234567')
    end
  end
end
