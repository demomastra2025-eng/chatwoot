require 'rails_helper'

# M3/M8: a public API client (no verified identity) never attaches a chat to a patient card, never takes a family number
# that another contact reserved or keeps as a recorded доп. номер, and never becomes a chat identity of a number.
RSpec.describe 'Public API contacts and patient cards', type: :request do
  let(:account) { create(:account) }
  let(:api_channel) { create(:channel_api, account: account, webhook_url: nil) }
  let(:path) { "/public/api/v1/inboxes/#{api_channel.identifier}/contacts" }
  let(:family) { '+77000000009' }
  let(:iin) { '940720300129' }
  let(:shared) { Contacts::SharedPhone }

  def created_contact
    api_channel.inbox.contact_inboxes.find_by(source_id: response.parsed_body['source_id'])&.contact
  end

  def card_sharing(owner, via:)
    create(:contact, account: account, name: 'Child', custom_attributes: {
             shared::CARD_KEY => true, 'secondary_phones' => [family], shared::SHARED_PHONE_KEY => family,
             shared::SHARED_OWNER_KEY => owner.id, shared::SHARED_VIA_KEY => via
           })
  end

  it 'P1 an unverified identifier equal to a card IIN creates a separate contact and reveals nothing of the card', :aggregate_failures do
    card = create(:contact, account: account, name: 'Child', identifier: iin, custom_attributes: { shared::CARD_KEY => true, 'iin' => iin })

    post path, params: { identifier: iin, name: 'Anyone' }, as: :json

    expect(response).to have_http_status(:success)
    expect(created_contact).to be_present
    expect(created_contact.id).not_to eq(card.id)
    expect(created_contact.identifier).to be_nil
    expect(response.parsed_body['id']).not_to eq(card.id)
    expect(response.body).not_to include('Child')
    expect(card.reload.contact_inboxes).to be_empty
  end

  it 'P1 an HMAC-verified identifier still reaches its own card' do
    card = create(:contact, account: account, name: 'Child', identifier: iin, custom_attributes: { shared::CARD_KEY => true })
    identifier_hash = OpenSSL::HMAC.hexdigest('sha256', api_channel.hmac_token, iin)

    post path, params: { identifier: iin, identifier_hash: identifier_hash }, as: :json

    expect(created_contact.id).to eq(card.id)
  end

  it 'P2 does not take a number reserved for the unresolved hidden share; the booking chat can still reveal it', :aggregate_failures do
    owner = create(:contact, account: account, name: 'Mother', phone_number: nil)
    card_sharing(owner, via: 'booking_chat')

    post path, params: { phone_number: family, name: 'Anyone' }, as: :json

    expect(response).to have_http_status(:success)
    expect(created_contact.phone_number).to be_nil
    expect(shared.assignable_primary?(account_id: account.id, phone: family, contact_id: owner.id)).to be(true)
  end

  it 'H2 does not take a released family number that a card keeps as доп. номер', :aggregate_failures do
    card_sharing(create(:contact, account: account, name: 'Mother', phone_number: '+77000000008'), via: 'owner_primary')

    post path, params: { phone_number: family, name: 'Stranger' }, as: :json

    expect(created_contact.phone_number).to be_nil
    expect(shared.primary_holder(account_id: account.id, phone: family)).to be_nil
  end

  it 'still gives a free number that nobody shares to the new contact' do
    post path, params: { phone_number: '+77000000031', name: 'Anyone' }, as: :json

    expect(created_contact.phone_number).to eq('+77000000031')
  end

  it 'P3 a client-chosen source id equal to the number is not a chat identity of that number' do
    post path, params: { source_id: family.delete('+'), name: 'Anyone' }, as: :json

    expect(response).to have_http_status(:success)
    expect(shared.identity_owner_ids(account_id: account.id, phone: family)).to be_empty
  end
end
