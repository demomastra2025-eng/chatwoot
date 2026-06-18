require 'rails_helper'

RSpec.describe Api::V1::Accounts::InboxWhatsappFlowsController, type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:whatsapp_channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:whatsapp_inbox) { whatsapp_channel.inbox }
  let(:web_widget_inbox) { create(:inbox, account: account) }

  let(:valid_flow_params) do
    {
      flow: {
        provider_flow_id: 'flow-123',
        name: 'lead_qualification',
        title: 'Lead qualification',
        status: 'published',
        mode: 'published',
        flow_json: { version: '6.0', screens: [] },
        metadata: { source: 'manual' }
      }
    }
  end

  before do
    create(:inbox_member, user: agent, inbox: whatsapp_inbox)
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_flows' do
    it 'returns unauthorized for unauthenticated users' do
      get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns unauthorized for non-admin users' do
      get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns bad request for non-cloud inboxes' do
      get "/api/v1/accounts/#{account.id}/inboxes/#{web_widget_inbox.id}/whatsapp_flows",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to eq('WhatsApp Flow management is only available for WhatsApp Cloud channels')
    end

    it 'lists only flows from the requested inbox and account' do
      visible_flow = create(:whatsapp_flow, account: account, inbox: whatsapp_inbox, name: 'visible_flow')
      other_channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      create(:whatsapp_flow, account: other_channel.account, inbox: other_channel.inbox, name: 'hidden_flow')

      get "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows",
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payload'].pluck('id')).to eq([visible_flow.id])
      expect(response.parsed_body['payload'].first).to include(
        'name' => 'visible_flow',
        'display_title' => visible_flow.display_title,
        'status' => 'published'
      )
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_flows' do
    it 'creates an inbox-scoped WhatsApp Flow' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows",
           headers: admin.create_new_auth_token,
           params: valid_flow_params,
           as: :json

      expect(response).to have_http_status(:created)
      flow = Whatsapp::Flow.find(response.parsed_body['id'])
      expect(flow).to have_attributes(
        account_id: account.id,
        inbox_id: whatsapp_inbox.id,
        provider_flow_id: 'flow-123',
        name: 'lead_qualification',
        status: 'published'
      )
      expect(response.parsed_body['flow_json']).to include('version' => '6.0')
    end

    it 'rejects duplicate names within an inbox' do
      create(:whatsapp_flow, account: account, inbox: whatsapp_inbox, name: 'lead_qualification')

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows",
           headers: admin.create_new_auth_token,
           params: valid_flow_params,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('Name has already been taken')
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_flows/{id}' do
    it 'updates an inbox-scoped WhatsApp Flow' do
      flow = create(:whatsapp_flow, account: account, inbox: whatsapp_inbox, name: 'lead_qualification')

      patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows/#{flow.id}",
            headers: admin.create_new_auth_token,
            params: { flow: { title: 'Updated title', status: 'draft' } },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(flow.reload).to have_attributes(title: 'Updated title', status: 'draft')
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_flows/{id}' do
    it 'deletes an inbox-scoped WhatsApp Flow' do
      flow = create(:whatsapp_flow, account: account, inbox: whatsapp_inbox)

      delete "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows/#{flow.id}",
             headers: admin.create_new_auth_token,
             as: :json

      expect(response).to have_http_status(:no_content)
      expect(Whatsapp::Flow.exists?(flow.id)).to be(false)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/inboxes/{inbox.id}/whatsapp_flows/{id}/sessions' do
    it 'creates a send session without exposing the flow token' do
      flow = create(:whatsapp_flow, account: account, inbox: whatsapp_inbox)
      conversation = create(:conversation, account: account, inbox: whatsapp_inbox)

      post "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}/whatsapp_flows/#{flow.id}/sessions",
           headers: admin.create_new_auth_token,
           params: { session: { conversation_id: conversation.id, metadata: { source: 'composer' } } },
           as: :json

      expect(response).to have_http_status(:created)
      session = Whatsapp::FlowSession.find(response.parsed_body['id'])
      expect(session).to have_attributes(
        account_id: account.id,
        inbox_id: whatsapp_inbox.id,
        whatsapp_flow_id: flow.id,
        conversation_id: conversation.id,
        status: 'pending'
      )
      expect(session.token).to be_present
      expect(session.token_digest).to eq(Whatsapp::FlowSession.digest_token(session.token))
      expect(session.token_prefix).to eq(session.token.first(8))
      expect(response.parsed_body).not_to have_key('token')
      expect(response.parsed_body).not_to have_key('token_digest')
      expect(response.parsed_body['token_prefix']).to eq(session.token_prefix)
      expect(response.parsed_body['metadata']).to eq('source' => 'composer')
    end
  end
end
