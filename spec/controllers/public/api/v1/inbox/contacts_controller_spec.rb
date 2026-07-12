require 'rails_helper'

RSpec.describe 'Public Inbox Contacts API', type: :request do
  let!(:account) { create(:account, limits: { non_web_inboxes: 10 }) }
  let!(:api_channel) { create(:channel_api, account: account) }
  let!(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: api_channel.inbox) }

  describe 'POST /public/api/v1/inboxes/{identifier}/contact' do
    it 'creates a contact and return the source id' do
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts"

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data.keys).to include('email', 'id', 'name', 'phone_number', 'pubsub_token', 'source_id')
      expect(data['source_id']).not_to be_nil
      expect(data['pubsub_token']).not_to be_nil
    end

    it 'persists the identifier of the contact' do
      identifier = 'contact-identifier'
      post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts", params: { identifier: identifier }

      expect(response).to have_http_status(:success)
      db_contact = api_channel.account.contacts.find_by(identifier: identifier)
      expect(db_contact).not_to be_nil
    end

    it 'reuses the contact inbox when the same source id is retried' do
      source_id = 'salebot-contact-1'
      path = "/public/api/v1/inboxes/#{api_channel.identifier}/contacts"

      expect do
        post path, params: { source_id: source_id, identifier: 'external-contact-1' }
        expect(response).to have_http_status(:success)
        first_response = response.parsed_body

        post path, params: { source_id: source_id, identifier: 'external-contact-1' }
        expect(response).to have_http_status(:success)
        expect(response.parsed_body['id']).to eq(first_response['id'])
        expect(response.parsed_body['source_id']).to eq(source_id)
      end.to change(ContactInbox, :count).by(1)
    end

    it 'rolls back contact creation when channel profile persistence fails' do
      invalid_profile = ContactChannelProfile.new
      invalid_profile.errors.add(:base, 'profile persistence failed')
      error = ActiveRecord::RecordInvalid.new(invalid_profile)
      profile_service = instance_double(Contacts::ChannelProfileUpsertService)
      allow(Contacts::ChannelProfileUpsertService).to receive(:new).and_return(profile_service)
      allow(profile_service).to receive(:perform).and_raise(error)

      expect do
        post "/public/api/v1/inboxes/#{api_channel.identifier}/contacts", params: { identifier: 'atomic-contact' }
      end.not_to(change { api_channel.account.contacts.count })

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'GET /public/api/v1/inboxes/{identifier}/contact/{source_id}' do
    it 'gets a contact when present' do
      get "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}"

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data.keys).to include('email', 'id', 'name', 'phone_number', 'pubsub_token', 'source_id')
      expect(data['source_id']).to eq contact_inbox.source_id
      expect(data['pubsub_token']).to eq contact_inbox.pubsub_token
    end
  end

  describe 'PATCH /public/api/v1/inboxes/{identifier}/contact/{source_id}' do
    it 'updates a contact when present' do
      patch "/public/api/v1/inboxes/#{api_channel.identifier}/contacts/#{contact_inbox.source_id}",
            params: { name: 'John Smith' }

      expect(response).to have_http_status(:success)
      data = response.parsed_body
      expect(data['name']).to eq 'John Smith'
    end
  end
end
