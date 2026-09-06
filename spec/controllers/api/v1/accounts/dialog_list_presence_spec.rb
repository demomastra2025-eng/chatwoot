require 'rails_helper'

RSpec.describe 'Dialog list presence', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contacts) { create_list(:contact, 2, account: account) }

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: user, inbox: inbox)
    contacts.each do |contact|
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, status: :open)
      create(:message, account: account, inbox: inbox, conversation: conversation, sender: contact)
      conversation.reload.refresh_communication_thread!
    end
  end

  %w[conversations communication_threads].each do |endpoint|
    [:index, :filter].each do |action|
      it "batches and isolates contact presence across #{endpoint} #{action} responses" do
        key = OnlineStatusTracker.presence_key(account.id, 'Contact')
        OnlineStatusTracker.update_presence(account.id, 'Contact', contacts.first.id)
        headers = user.create_new_auth_token
        allow(Redis::Alfred).to receive(:zscores).and_call_original
        allow(Redis::Alfred).to receive(:zscore).and_call_original

        request_list(endpoint, action, headers)

        expect(response).to have_http_status(:ok)
        expect(sender_statuses).to include(contacts.first.id => 'online', contacts.last.id => 'offline')
        expect(Redis::Alfred).to have_received(:zscores).with(key, match_array(contacts.map { |contact| contact.id.to_s })).once
        contacts.each { |contact| expect(Redis::Alfred).not_to have_received(:zscore).with(key, contact.id) }
        expect(OnlineStatusTracker.presence_cache).to be_nil

        Redis::Alfred.delete(key)
        OnlineStatusTracker.update_presence(account.id + 100_000, 'Contact', contacts.first.id)
        request_list(endpoint, action, headers)
        expect(response).to have_http_status(:ok)
        expect(sender_statuses.values).to all(eq('offline'))
        expect(OnlineStatusTracker.presence_cache).to be_nil
      end
    end
  end

  def request_list(endpoint, action, headers)
    url = "/api/v1/accounts/#{account.id}/#{endpoint}"
    if action == :filter
      post "#{url}/filter", headers: headers, as: :json,
                           params: { payload: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }] }
    else
      get url, headers: headers, as: :json, params: { status: 'open', assignee_type: 'all' }
    end
  end

  def sender_statuses
    body = JSON.parse(response.body)
    (body.dig('data', 'payload') || body.fetch('payload')).to_h do |dialog|
      sender = dialog.dig('meta', 'sender') || dialog['contact']
      [sender.fetch('id'), sender.fetch('availability_status')]
    end
  end
end
