# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Conversations calls_only filter API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:text_inbox) { create(:inbox, account: account) }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).reload.inbox }

  let!(:mine_sip_call_conversation) do
    create(:conversation, account: account, inbox: text_inbox, status: :open, assignee: agent).tap do |conversation|
      create(:telephony_call_session, account: account, conversation: conversation, provider: 'wazo')
    end
  end

  let!(:unassigned_voice_conversation) do
    create(:conversation, account: account, inbox: voice_inbox, status: :open, assignee: nil)
  end

  let!(:colleague_whatsapp_call_conversation) do
    call = create(:call, account: account)
    create(:inbox_member, user: agent, inbox: call.inbox)
    call.conversation.update!(status: :open, assignee: colleague)
    call.conversation
  end

  let!(:unassigned_whatsapp_web_call_conversation) do
    create(
      :conversation,
      account: account,
      inbox: text_inbox,
      status: :open,
      assignee: nil,
      additional_attributes: { 'call_status' => 'ringing', 'call_provider' => 'whatsapp_web' }
    )
  end

  let!(:mine_text_conversation) do
    create(:conversation, account: account, inbox: text_inbox, status: :open, assignee: agent).tap do |conversation|
      create(:message, account: account, inbox: text_inbox, conversation: conversation, content: 'Текстовый вопрос без звонка')
    end
  end

  let!(:unassigned_text_conversation) do
    create(:conversation, account: account, inbox: text_inbox, status: :open, assignee: nil).tap do |conversation|
      create(:message, account: account, inbox: text_inbox, conversation: conversation, content: 'Ещё один текстовый чат')
    end
  end

  before do
    create(:inbox_member, user: agent, inbox: text_inbox)
    create(:inbox_member, user: agent, inbox: voice_inbox)
  end

  describe 'GET /api/v1/accounts/:account_id/conversations' do
    it 'filters conversations to calls only and updates assignee tab counters accurately' do
      get "/api/v1/accounts/#{account.id}/conversations",
          headers: headers,
          params: { status: 'open', assignee_type: 'all', calls_only: 'true' },
          as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body.deep_symbolize_keys
      payload = body.dig(:data, :payload)
      meta = body.dig(:data, :meta)

      expect(payload.pluck(:id)).to contain_exactly(
        mine_sip_call_conversation.display_id,
        unassigned_voice_conversation.display_id,
        colleague_whatsapp_call_conversation.display_id,
        unassigned_whatsapp_web_call_conversation.display_id
      )
      expect(payload.pluck(:has_calls)).to all(be(true))
      expect(meta).to include(
        mine_count: 1,
        assigned_count: 2,
        unassigned_count: 2,
        all_count: 4
      )
    end

    it 'accepts calls_only=1 and returns all conversations with accurate has_calls flags when calls_only=false' do
      get "/api/v1/accounts/#{account.id}/conversations",
          headers: headers,
          params: { status: 'open', assignee_type: 'me', calls_only: '1' },
          as: :json

      expect(response).to have_http_status(:ok)
      filtered_payload = response.parsed_body.deep_symbolize_keys.dig(:data, :payload)
      expect(filtered_payload.pluck(:id)).to eq([mine_sip_call_conversation.display_id])

      get "/api/v1/accounts/#{account.id}/conversations",
          headers: headers,
          params: { status: 'open', assignee_type: 'all', calls_only: 'false' },
          as: :json

      expect(response).to have_http_status(:ok)
      unfiltered_payload = response.parsed_body.deep_symbolize_keys.dig(:data, :payload)
      by_id = unfiltered_payload.index_by { |item| item[:id] }

      expect(by_id.keys).to include(mine_text_conversation.display_id, unassigned_text_conversation.display_id)
      expect(by_id[mine_sip_call_conversation.display_id][:has_calls]).to be(true)
      expect(by_id[mine_text_conversation.display_id][:has_calls]).to be(false)
      expect(by_id[unassigned_text_conversation.display_id][:has_calls]).to be(false)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/conversations/meta' do
    it 'returns filtered assignee tab counters matching calls_only=true' do
      get "/api/v1/accounts/#{account.id}/conversations/meta",
          headers: headers,
          params: { status: 'open', calls_only: 'true' },
          as: :json

      expect(response).to have_http_status(:ok)
      meta = response.parsed_body.deep_symbolize_keys[:meta]
      expect(meta).to include(
        mine_count: 1,
        assigned_count: 2,
        unassigned_count: 2,
        all_count: 4
      )
    end
  end

  describe 'POST /api/v1/accounts/:account_id/conversations/filter' do
    it 'applies calls_only alongside advanced filter rules' do
      post "/api/v1/accounts/#{account.id}/conversations/filter?calls_only=true",
           headers: headers,
           params: {
             payload: [
               {
                 attribute_key: 'status',
                 filter_operator: 'equal_to',
                 values: ['open'],
                 query_operator: nil
               }
             ]
           },
           as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body.deep_symbolize_keys
      expect(body[:payload].pluck(:id)).to contain_exactly(
        mine_sip_call_conversation.display_id,
        unassigned_voice_conversation.display_id,
        colleague_whatsapp_call_conversation.display_id,
        unassigned_whatsapp_web_call_conversation.display_id
      )
      expect(body[:meta][:all_count]).to eq(4)
    end
  end

  describe 'BulkActions::SelectionSnapshot integration' do
    it 'snapshots only call conversations in both basic and advanced modes' do
      basic_snapshot = BulkActions::SelectionSnapshot.new(
        account: account,
        user: agent,
        resource_type: 'Conversation',
        filters: { mode: 'basic', status: 'open', assignee_type: 'all', calls_only: true }
      ).perform

      expect(basic_snapshot.ids).to contain_exactly(
        mine_sip_call_conversation.display_id,
        unassigned_voice_conversation.display_id,
        colleague_whatsapp_call_conversation.display_id,
        unassigned_whatsapp_web_call_conversation.display_id
      )

      advanced_snapshot = BulkActions::SelectionSnapshot.new(
        account: account,
        user: agent,
        resource_type: 'Conversation',
        filters: {
          mode: 'advanced',
          callsOnly: true,
          queryData: {
            payload: [
              {
                attribute_key: 'status',
                filter_operator: 'equal_to',
                values: ['open'],
                query_operator: nil
              }
            ]
          }
        }
      ).perform

      expect(advanced_snapshot.ids).to match_array(basic_snapshot.ids)
    end
  end
end
