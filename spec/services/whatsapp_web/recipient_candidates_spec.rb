require 'rails_helper'

RSpec.describe WhatsappWeb::RecipientCandidates do
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
  let(:lid_jid) { '143907392331785@lid' }
  let(:phone_digits) { '77012345678' }
  let(:contact) { create(:contact, account: channel.account, phone_number: "+#{phone_digits}", additional_attributes: contact_attributes) }
  let(:contact_attributes) { {} }

  def conversation_for(contact_inbox)
    create(:conversation, account: channel.account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)
  end

  def candidates_for(contact_inbox)
    described_class.new(conversation: conversation_for(contact_inbox)).to_a
  end

  it 'starts with the matched profile, the contact attributes and the conversation source id, and ends with the contact phone' do
    contact.update!(
      additional_attributes: {
        'canonical_jid' => "#{phone_digits}@s.whatsapp.net",
        'channel_profiles' => {
          'whatsapp_web' => {
            'whatsapp_web:one' => {
              'source_id' => phone_digits, 'canonical_jid' => "#{phone_digits}@s.whatsapp.net", 'raw_jid' => "#{phone_digits}@s.whatsapp.net"
            }
          }
        }
      }
    )
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: phone_digits)

    expect(candidates_for(contact_inbox)).to eq(["#{phone_digits}@s.whatsapp.net", phone_digits, "+#{phone_digits}"])
  end

  context 'when the conversation hangs on a LID contact inbox' do
    let(:contact_attributes) do
      {
        'raw_jid' => lid_jid,
        'channel_profiles' => {
          'whatsapp_web' => {
            "whatsapp_web:#{lid_jid}" => { 'source_id' => lid_jid, 'raw_jid' => lid_jid, 'lid_jid' => lid_jid }
          }
        }
      }
    end
    let(:lid_contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: lid_jid) }

    it 'lists the LID first and then the phone identities of the same contact' do
      phone_contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: phone_digits)
      create(:contact_channel_profile, contact_inbox: phone_contact_inbox, profile_data: { 'canonical_jid' => "#{phone_digits}@s.whatsapp.net" })

      expect(candidates_for(lid_contact_inbox)).to eq([lid_jid, "#{phone_digits}@s.whatsapp.net", phone_digits, "+#{phone_digits}"])
    end

    it 'puts the phone identity tied to this LID before the other phone identities' do
      other = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '77055555555')
      create(:contact_channel_profile, contact_inbox: other, profile_data: { 'canonical_jid' => '77055555555@s.whatsapp.net' })
      tied = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: phone_digits)
      create(
        :contact_channel_profile,
        contact_inbox: tied,
        profile_data: { 'canonical_jid' => "#{phone_digits}@s.whatsapp.net", 'lid_jid' => lid_jid }
      )

      expect(candidates_for(lid_contact_inbox).drop(1).first).to eq("#{phone_digits}@s.whatsapp.net")
    end

    it 'does not borrow identities from other contacts or other inboxes' do
      stranger = create(:contact, account: channel.account, phone_number: nil)
      create(:contact_inbox, inbox: channel.inbox, contact: stranger, source_id: '77099999999')
      other_inbox_channel = create(:channel_whatsapp_web, account: channel.account)
      create(:contact_inbox, inbox: other_inbox_channel.inbox, contact: contact, source_id: '77088888888')

      expect(candidates_for(lid_contact_inbox)).to eq([lid_jid, "+#{phone_digits}"])
    end

    it 'reads phone profiles kept in the legacy channel_profiles attribute' do
      contact.update!(
        additional_attributes: contact_attributes.deep_merge(
          'channel_profiles' => {
            'whatsapp_web' => {
              'whatsapp_web:phone' => { 'source_id' => phone_digits, 'canonical_jid' => "#{phone_digits}@s.whatsapp.net", 'lid_jid' => lid_jid }
            }
          }
        )
      )

      expect(candidates_for(lid_contact_inbox)).to include("#{phone_digits}@s.whatsapp.net")
    end
  end

  it 'returns nothing blank when the contact has no identity at all' do
    contact.update!(phone_number: nil)
    contact_inbox = create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: lid_jid)

    expect(candidates_for(contact_inbox)).to eq([lid_jid])
  end
end
