require 'rails_helper'

RSpec.describe 'Contacts API phonebook bootstrap', type: :request do
  let(:channel) { create(:channel_whatsapp_web) }
  let(:account) { channel.account }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:source_id) { '15550000011' }
  let(:automatic_source) do
    { 'kind' => 'channel_profile', 'provider' => 'whatsapp_web', 'inbox_id' => channel.inbox.id, 'source_id' => source_id }
  end

  def create_native_contact(preference = automatic_source)
    attrs = preference ? { display_preferences: { primary_name_source: preference } } : {}
    post "/api/v1/accounts/#{account.id}/contacts", headers: admin.create_new_auth_token, as: :json,
                                                    params: { name: 'Profile Name', phone_number: '+15550000011',
                                                              inbox_id: channel.inbox.id, source_id: source_id, additional_attributes: attrs }
    expect(response).to have_http_status(:success)
    Contact.find(response.parsed_body.dig('payload', 'contact', 'id'))
  end

  def deliver_saved_name
    WhatsappWeb::ContactSyncService.new(channel: channel, contact_payload: {
                                          remoteJid: '15550000011@s.whatsapp.net', pushName: 'Profile Name',
                                          phonebookName: 'Saved Alias', phonebookNameUpdatedAt: '2026-11-01T12:00:00Z'
                                        }).perform
  end

  it 'accepts the first saved name after a marked native API create', :aggregate_failures do
    contact = create_native_contact
    deliver_saved_name

    expect(contact.reload.name).to eq('Saved Alias')
    expect(contact.primary_name_source).to include('kind' => 'channel_profile', 'inbox_id' => channel.inbox.id)
  end

  it 'accepts a matching declared source when a legacy contact inbox has no profile yet', :aggregate_failures do
    contact = create_native_contact
    contact.contact_channel_profiles.destroy_all
    deliver_saved_name

    expect(contact.reload.name).to eq('Saved Alias')
    expect(contact.contact_channel_profiles.first.profile_data['phonebook_name']).to eq('Saved Alias')
  end

  it 'preserves a meaningful unmarked API-created name' do
    contact = create_native_contact(nil)
    deliver_saved_name

    expect(contact.reload.name).to eq('Profile Name')
  end

  it 'preserves an explicit manual API-created name' do
    contact = create_native_contact('kind' => 'manual')
    deliver_saved_name

    expect(contact.reload.name).to eq('Profile Name')
    expect(contact.primary_name_source).to eq('kind' => 'manual')
  end

  %w[inbox_id source_id].each do |mismatched_key|
    it "does not bootstrap a declared source with a mismatched #{mismatched_key}" do
      wrong_value = mismatched_key == 'inbox_id' ? channel.inbox.id + 1 : '15550000099'
      contact = create_native_contact(automatic_source.merge(mismatched_key => wrong_value))
      contact.contact_channel_profiles.destroy_all
      deliver_saved_name

      expect(contact.reload.name).to eq('Profile Name')
    end
  end

  it 'does not promote a self-declared WhatsApp source on a generic API inbox' do
    generic = create(:channel_api, account: account)
    generic_inbox = create(:inbox, account: account, channel: generic)
    marker = automatic_source.merge('inbox_id' => generic_inbox.id, 'source_id' => 'opaque-api-source')
    post "/api/v1/accounts/#{account.id}/contacts", headers: admin.create_new_auth_token, as: :json,
                                                    params: { name: 'Generic Profile', inbox_id: generic_inbox.id, source_id: 'opaque-api-source',
                                                              additional_attributes: { display_preferences: { primary_name_source: marker } } }
    expect(response).to have_http_status(:success)
    contact = Contact.find(response.parsed_body.dig('payload', 'contact', 'id'))
    contact.contact_channel_profiles.destroy_all
    source = contact.contact_inboxes.find_by!(inbox_id: generic_inbox.id)

    expect(contact.name_updates_allowed_for?(contact_inbox: source, replaceable_current_name: false)).to be(false)
  end

  it 'does not accept another account contact inbox as a pending source' do
    contact = create_native_contact
    other_channel = create(:channel_whatsapp_web)
    other_contact = create(:contact, account: other_channel.account)
    other_source = create(:contact_inbox, inbox: other_channel.inbox, contact: other_contact, source_id: source_id)
    contact.update!(additional_attributes: contact.merge_display_source(
      additional_attributes: contact.additional_attributes,
      key: Contact::PRIMARY_NAME_SOURCE_KEY,
      source: automatic_source.merge('inbox_id' => other_channel.inbox.id)
    ))
    contact.contact_channel_profiles.destroy_all

    expect(contact.name_updates_allowed_for?(contact_inbox: other_source, replaceable_current_name: false)).to be(false)
  end
end
