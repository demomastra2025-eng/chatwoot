require 'rails_helper'

RSpec.describe 'Conversation message reactions API', type: :request do
  around do |example|
    with_modified_env('TELEGRAM_PERSONAL_GATEWAY_URL' => 'http://telegram-personal-gateway.test',
                      'TELEGRAM_PERSONAL_GATEWAY_TOKEN' => 'test-gateway-token') { example.run }
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:channel) { create(:channel_telegram_personal, account: account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, source_id: '23') }
  let(:conversation) do
    create(:conversation, account: account, inbox: channel.inbox, contact_inbox: contact_inbox,
                          contact: contact_inbox.contact, additional_attributes: { chat_id: '23' })
  end
  let(:message) do
    create(:message, account: account, inbox: channel.inbox, conversation: conversation, source_id: '42', content: 'Original message')
  end
  let(:gateway_path) { "http://telegram-personal-gateway.test/internal/channels/#{channel.id}/messages/react" }

  before do
    create(:inbox_member, inbox: channel.inbox, user: user)
  end

  def react
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/messages/#{message.id}/react",
         params: { emoji: '👍' }, headers: { api_access_token: user.access_token.token }, as: :json
  end

  it 'returns an error instead of an optimistic reaction when the provider cannot deliver it' do
    request = stub_request(:post, gateway_path).to_return(
      status: 503, body: { error: 'Gateway unavailable' }.to_json, headers: { 'Content-Type' => 'application/json' }
    )

    react

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq('Gateway unavailable')
    expect(request).to have_been_requested.once
    expect(message.reload.content_attributes['agent_reactions']).to be_nil
    expect(message.content_attributes['telegram_reactions']).to be_nil
  end

  it 'permits retry after an error and returns the confirmed provider reaction' do
    request = stub_request(:post, gateway_path).to_return(
      { status: 503, body: { error: 'Gateway unavailable' }.to_json, headers: { 'Content-Type' => 'application/json' } },
      { status: 200, body: { message_id: '42' }.to_json, headers: { 'Content-Type' => 'application/json' } }
    )

    react
    expect(response).to have_http_status(:unprocessable_content)
    react

    expect(response).to have_http_status(:success)
    expect(request).to have_been_requested.twice
    expect(response.parsed_body.dig('content_attributes', 'telegram_reactions', 'total_count')).to eq(1)
    expect(message.reload.content_attributes.dig('agent_reactions', "user:#{user.id}", 'emoji')).to eq('👍')
    expect(message.content_attributes['edited']).to be_nil
  end
end
