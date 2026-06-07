require 'rails_helper'

RSpec.describe Whatsapp::ContactIdentityResolver do
  let(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:sender_phone_source_id) { '77001234567' }
  let(:bsuid_source_id) { '111122223333444' }
  let(:message) { { from: sender_phone_source_id, id: 'wamid.inbound-1', type: 'text' }.with_indifferent_access }
  let(:contact_params) do
    { profile: { name: 'Customer Name' }, wa_id: bsuid_source_id }.with_indifferent_access
  end

  it 'creates a secondary BSUID contact inbox for an existing phone contact' do
    contact = create(:contact, account: inbox.account, phone_number: "+#{sender_phone_source_id}")
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: sender_phone_source_id)

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: contact_params).perform

    expect(contact_inbox.source_id).to eq(bsuid_source_id)
    expect(contact_inbox.contact_id).to eq(contact.id)
    expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly(sender_phone_source_id, bsuid_source_id)
  end

  it 'prefers explicit BSUID fields over legacy phone wa_id payloads' do
    contact = create(:contact, account: inbox.account, phone_number: "+#{sender_phone_source_id}")
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: sender_phone_source_id)
    mixed_contact_params = {
      profile: { name: 'Customer Name' },
      wa_id: sender_phone_source_id,
      user_id: bsuid_source_id
    }.with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: mixed_contact_params).perform

    expect(contact_inbox.source_id).to eq(bsuid_source_id)
    expect(contact_inbox.contact_id).to eq(contact.id)
    expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly(sender_phone_source_id, bsuid_source_id)
  end

  it 'stores BSUIDs without phone-number normalization collisions' do
    colliding_bsuid = '551198888777'
    normalized_brazil_phone = '5511998888777'
    contact = create(:contact, account: inbox.account, phone_number: "+#{sender_phone_source_id}")
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: normalized_brazil_phone)
    colliding_contact_params = {
      profile: { name: 'Customer Name' },
      wa_id: colliding_bsuid
    }.with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: colliding_contact_params).perform

    expect(contact_inbox.source_id).to eq(colliding_bsuid)
    expect(contact_inbox.contact_id).to eq(contact.id)
    expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly(normalized_brazil_phone, colliding_bsuid)
  end

  it 'backfills the sender phone number onto an existing BSUID-only contact' do
    contact = create(:contact, account: inbox.account, phone_number: nil)
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: bsuid_source_id)

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: contact_params).perform

    expect(contact_inbox.contact_id).to eq(contact.id)
    expect(contact.reload.phone_number).to eq("+#{sender_phone_source_id}")
  end

  it 'falls back to the sender phone when provider contact identifiers are invalid' do
    invalid_contact_params = {
      profile: { name: 'Customer Name' },
      wa_id: 'not-a-bsuid',
      user_id: 'not-a-valid-provider-id',
      parent_user_id: 'chat:12345'
    }.with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: invalid_contact_params).perform

    expect(contact_inbox.source_id).to eq(sender_phone_source_id)
    expect(contact_inbox.contact.phone_number).to eq("+#{sender_phone_source_id}")
  end

  it 'normalizes WhatsApp-prefixed outgoing echo destinations' do
    echo_message = { to: "whatsapp:+#{sender_phone_source_id}", id: 'wamid.echo-1', type: 'text' }.with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: echo_message, outgoing_echo: true).perform

    expect(contact_inbox.source_id).to eq(sender_phone_source_id)
    expect(contact_inbox.contact.phone_number).to eq("+#{sender_phone_source_id}")
    expect(contact_inbox.contact.name).to eq("+#{sender_phone_source_id}")
  end
end
