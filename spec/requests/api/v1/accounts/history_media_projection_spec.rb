require 'rails_helper'

RSpec.describe 'Public history media metadata', type: :request do
  let(:message) { create(:message, content: 'Historical caption', content_attributes: attributes) }
  let(:provider_url) { 'https://media.example.test/private.enc?token=synthetic-private' }
  let(:attributes) do
    {
      'history_attachment' => { 'kind' => 'image', 'file_name' => 'old.png', 'unavailable' => true, 'deferred' => true,
                                'fetch_state' => 'unavailable', 'media_url' => provider_url, 'media_key' => 'synthetic-key' },
      'telegram_unavailable_attachments' => [{ 'kind' => 'photo', 'filename' => 'old.png', 'url' => provider_url }],
      'prompt' => 'Dashboard AI context', 'imported_history' => true
    }
  end

  it 'keeps private media references out of REST while preserving captions and safe states' do
    admin = create(:user, account: message.account, role: :administrator)
    get "/api/v1/accounts/#{message.account_id}/conversations/#{message.conversation.display_id}/messages", headers: admin.create_new_auth_token
    expect(response).to have_http_status(:success)
    expect(response.body).not_to include(provider_url, 'synthetic-key')
    expect(response.body).to include('Historical caption', 'old.png', 'fetch_state')
    expect(message.reload.content_attributes).to eq(attributes)
  end

  it 'uses the same projection for dashboard, external, webhook and previous values without changing AI visibility' do
    payloads = [message.push_event_data, message.external_push_event_data, message.webhook_push_event_data, message.webhook_data,
                message.external_content_attributes, message.public_previous_changes(content_attributes: [attributes, attributes]),
                message.external_previous_changes(content_attributes: [attributes, attributes])]
    expect(payloads.to_json).not_to include(provider_url, 'synthetic-key')
    expect(message.push_event_data[:content_attributes]['prompt']).to eq('Dashboard AI context')
    expect(message.external_content_attributes).not_to have_key('prompt')
    expect(message.public_content_attributes['history_attachment']).to include('kind' => 'image', 'deferred' => true)
  end

  it 'filters dashboard and customer websocket previous_changes as well as the current message' do
    agent = create(:user, account: message.account, role: :agent)
    create(:inbox_member, inbox: message.inbox, user: agent)
    event = Events::Base.new(:'message.updated', Time.current, message: message, previous_changes: { content_attributes: [attributes, attributes] })
    payloads = []
    allow(ActionCableBroadcastJob).to receive(:perform_later) { |_, name, data| payloads << data if name == 'message.updated' }
    ActionCableListener.instance.message_updated(event)
    expect(payloads.size).to eq(2)
    expect(payloads.to_json).not_to include(provider_url, 'synthetic-key')
    expect(payloads.first[:previous_changes][:content_attributes].first['history_attachment']).to include('kind' => 'image')
  end

  it 'normalizes legacy encoded metadata and handles malformed buckets without exposing private fields' do
    expect(Messages::HistoryMediaProjection.call(attributes.to_json).to_json).not_to include(provider_url, 'synthetic-key')
    expect(Messages::HistoryMediaProjection.call('not json')).to eq({})
    expect(Messages::HistoryMediaProjection.call('history_attachment' => provider_url)).to eq('history_attachment' => nil)
    malformed = { 'history_attachment' => { 'kind' => 'image', 'file_name' => { 'url' => provider_url }, 'mimetype' => [provider_url],
                                            'unavailable' => true, 'fetch_state' => nil } }
    expect(Messages::HistoryMediaProjection.call(malformed)).to eq(
      'history_attachment' => { 'kind' => 'image', 'unavailable' => true, 'fetch_state' => nil }
    )
  end
end
