require 'rails_helper'

RSpec.describe Whatsapp::ContactIdentityResolver do
  let(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:sender_phone_source_id) { '77001234567' }
  let(:bsuid_source_id) { 'IN.2081978709342942' }
  let(:parent_bsuid_source_id) { 'IN.ENT.9081726354' }
  let(:message) do
    {
      from: sender_phone_source_id,
      from_user_id: bsuid_source_id,
      from_parent_user_id: parent_bsuid_source_id,
      id: 'wamid.inbound-1',
      type: 'text'
    }.with_indifferent_access
  end
  let(:contact_params) do
    {
      profile: { name: 'Customer Name', username: '@customer' },
      wa_id: sender_phone_source_id,
      user_id: bsuid_source_id,
      parent_user_id: parent_bsuid_source_id
    }.with_indifferent_access
  end

  it 'links phone and BSUID source ids to the same existing phone contact' do
    contact = create(:contact, account: inbox.account, phone_number: "+#{sender_phone_source_id}")
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: sender_phone_source_id)

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: contact_params).perform

    bsuid_contact_inbox = inbox.contact_inboxes.find_by!(source_id: bsuid_source_id)
    parent_contact_inbox = inbox.contact_inboxes.find_by!(source_id: parent_bsuid_source_id)
    expect(contact_inbox.contact_id).to eq(contact.id)
    expect(bsuid_contact_inbox.contact_id).to eq(contact.id)
    expect(parent_contact_inbox.contact_id).to eq(contact.id)
    expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly(
      sender_phone_source_id,
      bsuid_source_id,
      parent_bsuid_source_id
    )
  end

  it 'creates a BSUID-only contact without a fake phone number' do
    bsuid_only_message = message.except(:from).with_indifferent_access
    bsuid_only_contact_params = contact_params.except(:wa_id).with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: bsuid_only_message, contact_params: bsuid_only_contact_params).perform

    contact = contact_inbox.contact
    expect(contact_inbox.source_id).to eq(bsuid_source_id)
    expect(contact).to have_attributes(name: 'Customer Name', phone_number: nil)
    expect(contact.additional_attributes).to include(
      'social_whatsapp_user_name' => 'customer',
      'social_profiles' => { 'whatsapp' => 'customer' }
    )
    expect(inbox.contact_inboxes.find_by!(source_id: parent_bsuid_source_id).contact_id).to eq(contact.id)
  end

  it 'backfills the sender phone number onto an existing BSUID-only contact' do
    contact = create(:contact, account: inbox.account, phone_number: nil)
    create(:contact_inbox, inbox: inbox, contact: contact, source_id: bsuid_source_id)

    contact_inbox = described_class.new(inbox: inbox, message: message, contact_params: contact_params).perform

    expect(contact_inbox.contact_id).to eq(contact.id)
    expect(contact_inbox.source_id).to eq(sender_phone_source_id)
    expect(contact.reload.phone_number).to eq("+#{sender_phone_source_id}")
    expect(inbox.contact_inboxes.find_by!(source_id: sender_phone_source_id).contact_id).to eq(contact.id)
  end

  it 'falls back to the sender phone when provider contact identifiers are invalid' do
    invalid_contact_params = {
      profile: { name: 'Customer Name' },
      wa_id: sender_phone_source_id,
      user_id: 'not-a-bsuid',
      parent_user_id: 'chat:12345'
    }.with_indifferent_access
    phone_only_message = message.except(:from_user_id, :from_parent_user_id).with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: phone_only_message, contact_params: invalid_contact_params).perform

    expect(contact_inbox.source_id).to eq(sender_phone_source_id)
    expect(contact_inbox.contact.phone_number).to eq("+#{sender_phone_source_id}")
    expect(inbox.contact_inboxes.pluck(:source_id)).to contain_exactly(sender_phone_source_id)
  end

  it 'normalizes WhatsApp-prefixed outgoing echo destinations' do
    echo_message = {
      to: "whatsapp:+#{sender_phone_source_id}",
      id: 'wamid.echo-1',
      type: 'text'
    }.with_indifferent_access

    contact_inbox = described_class.new(inbox: inbox, message: echo_message, outgoing_echo: true).perform

    expect(contact_inbox.source_id).to eq(sender_phone_source_id)
    expect(contact_inbox.contact.phone_number).to eq("+#{sender_phone_source_id}")
    expect(contact_inbox.contact.name).to eq("+#{sender_phone_source_id}")
  end

  it 'does not treat BSUID values as phone numbers' do
    expect(described_class.normalize_source_id(bsuid_source_id)).to eq(bsuid_source_id)
    expect(described_class.phone_number_for(bsuid_source_id)).to be_nil
  end
end
