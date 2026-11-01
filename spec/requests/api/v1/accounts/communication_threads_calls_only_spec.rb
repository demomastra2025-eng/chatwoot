# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'CommunicationThreads calls_only filter API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:whatsapp_text_inbox) { create(:inbox, account: account) }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).reload.inbox }
  let(:restricted_voice_inbox) { create(:channel_voice, :sipuni, account: account).reload.inbox }

  let!(:mixed_mine_thread) do
    contact = create(:contact, account: account, name: 'Пациент Смешанный')
    thread = create(:communication_thread, account: account, contact: contact, status: 'open', assignee: agent)
    wa_text = create(:conversation, account: account, inbox: whatsapp_text_inbox, contact: contact, status: :open, assignee: agent)
    create(:message, account: account, inbox: whatsapp_text_inbox, conversation: wa_text, content: 'Написал в WhatsApp')
    sip_call = create(:conversation, account: account, inbox: whatsapp_text_inbox, contact: contact, status: :open, assignee: agent)
    create(:telephony_call_session, account: account, conversation: sip_call, provider: 'beeline')

    attach_to_thread!(thread, wa_text, primary: true)
    attach_to_thread!(thread, sip_call)
    thread
  end

  let!(:unassigned_voice_thread) do
    contact = create(:contact, account: account, name: 'Пациент Звонок')
    thread = create(:communication_thread, account: account, contact: contact, status: 'open', assignee: nil)
    voice_conv = create(:conversation, account: account, inbox: voice_inbox, contact: contact, status: :open, assignee: nil)
    attach_to_thread!(thread, voice_conv, primary: true)
    thread
  end

  let!(:colleague_whatsapp_call_thread) do
    call = create(:call, account: account)
    create(:inbox_member, user: agent, inbox: call.inbox)
    call.conversation.update!(status: :open, assignee: colleague)
    thread = create(:communication_thread, account: account, contact: call.contact, status: 'open', assignee: colleague)
    attach_to_thread!(thread, call.conversation, primary: true)
    thread
  end

  let!(:text_only_mine_thread) do
    contact = create(:contact, account: account, name: 'Пациент Только Текст')
    thread = create(:communication_thread, account: account, contact: contact, status: 'open', assignee: agent)
    text_conv = create(:conversation, account: account, inbox: whatsapp_text_inbox, contact: contact, status: :open, assignee: agent)
    create(:message, account: account, inbox: whatsapp_text_inbox, conversation: text_conv, content: 'Только переписка')
    attach_to_thread!(thread, text_conv, primary: true)
    thread
  end

  let!(:inaccessible_call_mixed_thread) do
    contact = create(:contact, account: account, name: 'Пациент Закрытая Телефония')
    thread = create(:communication_thread, account: account, contact: contact, status: 'open', assignee: nil)
    visible_text = create(:conversation, account: account, inbox: whatsapp_text_inbox, contact: contact, status: :open, assignee: nil)
    hidden_call = create(:conversation, account: account, inbox: restricted_voice_inbox, contact: contact, status: :open, assignee: nil)
    attach_to_thread!(thread, visible_text, primary: true)
    attach_to_thread!(thread, hidden_call)
    thread
  end

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: agent, inbox: whatsapp_text_inbox)
    create(:inbox_member, user: agent, inbox: voice_inbox)
    restricted_voice_inbox.inbox_members.where(user: agent).destroy_all
  end

  def attach_to_thread!(thread, conversation, primary: false)
    links = CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id)
    old_ids = links.pluck(:communication_thread_id) - [thread.id]
    links.delete_all
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
    create(:communication_thread_conversation, account: account, communication_thread: thread,
                                               conversation: conversation, primary: primary)
    old_ids.each do |id|
      CommunicationThread.where(id: id).delete_all unless CommunicationThreadConversation.exists?(communication_thread_id: id)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads' do
    it 'includes multi-channel threads containing accessible calls, excludes text-only threads, and updates tab counters' do
      get "/api/v1/accounts/#{account.id}/communication_threads",
          headers: headers,
          params: { status: 'open', assignee_type: 'all', calls_only: 'true' },
          as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body.deep_symbolize_keys
      payload = body.dig(:data, :payload)
      meta = body.dig(:data, :meta)

      expect(payload.pluck(:id)).to contain_exactly(
        mixed_mine_thread.display_id,
        unassigned_voice_thread.display_id,
        colleague_whatsapp_call_thread.display_id
      )
      expect(payload.pluck(:id)).not_to include(
        text_only_mine_thread.display_id,
        inaccessible_call_mixed_thread.display_id
      )
      expect(payload.pluck(:has_calls)).to all(be(true))
      expect(meta).to include(
        mine_count: 1,
        assigned_count: 2,
        unassigned_count: 1,
        all_count: 3
      )
    end

    it 'serializes accurate has_calls flags when calls_only is inactive' do
      get "/api/v1/accounts/#{account.id}/communication_threads",
          headers: headers,
          params: { status: 'open', assignee_type: 'all' },
          as: :json

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body.deep_symbolize_keys.dig(:data, :payload)
      by_id = payload.index_by { |item| item[:id] }

      expect(by_id[mixed_mine_thread.display_id][:has_calls]).to be(true)
      expect(by_id[unassigned_voice_thread.display_id][:has_calls]).to be(true)
      expect(by_id[text_only_mine_thread.display_id][:has_calls]).to be(false)
      expect(by_id[inaccessible_call_mixed_thread.display_id][:has_calls]).to be(false)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads/meta' do
    it 'returns filtered assignee tab counters when calls_only=true' do
      get "/api/v1/accounts/#{account.id}/communication_threads/meta",
          headers: headers,
          params: { status: 'open', calls_only: 'true' },
          as: :json

      expect(response).to have_http_status(:ok)
      meta = response.parsed_body.deep_symbolize_keys[:meta]
      expect(meta).to include(
        mine_count: 1,
        assigned_count: 2,
        unassigned_count: 1,
        all_count: 3
      )
    end
  end

  describe 'POST /api/v1/accounts/:account_id/communication_threads/filter' do
    it 'filters advanced thread queries and meta counters to threads with calls' do
      post "/api/v1/accounts/#{account.id}/communication_threads/filter?calls_only=true&include_meta=true",
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
      payload = body.dig(:data, :payload) || body[:payload]
      meta = body.dig(:data, :meta) || body[:meta]
      expect(payload.pluck(:id)).to contain_exactly(
        mixed_mine_thread.display_id,
        unassigned_voice_thread.display_id,
        colleague_whatsapp_call_thread.display_id
      )
      expect(meta[:all_count]).to eq(3)
      expect(meta[:mine_count]).to eq(1)
      expect(meta[:unassigned_count]).to eq(1)
    end

    it 'keeps an open thread whose open conversation is text-only when another linked conversation is a resolved call' do
      split_contact = create(:contact, account: account, name: 'Пациент Открытый WA + Завершённый Звонок')
      split_thread = create(:communication_thread, account: account, contact: split_contact, status: 'open', assignee: agent)
      open_wa_text = create(:conversation, account: account, inbox: whatsapp_text_inbox, contact: split_contact,
                                           status: :open, assignee: agent)
      create(:message, account: account, inbox: whatsapp_text_inbox, conversation: open_wa_text,
                       message_type: :incoming, content: 'Пишу в открытый WhatsApp после звонка')
      resolved_voice_call = create(:conversation, account: account, inbox: voice_inbox, contact: split_contact,
                                                  status: :resolved, assignee: agent)
      voice_binding = Telephony::NumberBinding.find_by!(inbox: voice_inbox)
      create(:telephony_call_session, account: account, conversation: resolved_voice_call,
                                      number_binding: voice_binding, provider: 'sipuni')

      attach_to_thread!(split_thread, open_wa_text, primary: true)
      attach_to_thread!(split_thread, resolved_voice_call)

      post "/api/v1/accounts/#{account.id}/communication_threads/filter?calls_only=true&include_meta=true",
           headers: headers,
           params: {
             payload: [
               {
                 attribute_key: 'status',
                 filter_operator: 'equal_to',
                 values: ['open'],
                 query_operator: 'and'
               },
               {
                 attribute_key: 'inbox_id',
                 filter_operator: 'equal_to',
                 values: [whatsapp_text_inbox.id],
                 query_operator: nil
               }
             ]
           },
           as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body.deep_symbolize_keys
      payload = body.dig(:data, :payload) || body[:payload]
      meta = body.dig(:data, :meta) || body[:meta]

      expect(payload.pluck(:id)).to contain_exactly(
        mixed_mine_thread.display_id,
        split_thread.display_id
      )
      expect(payload.pluck(:has_calls)).to all(be(true))
      expect(meta).to include(
        mine_count: 2,
        assigned_count: 2,
        unassigned_count: 0,
        all_count: 2
      )
    end
  end

  describe 'BulkActions::SelectionSnapshot integration' do
    it 'selects only threads with accessible calls when calls_only is active' do
      snapshot = BulkActions::SelectionSnapshot.new(
        account: account,
        user: agent,
        resource_type: 'CommunicationThread',
        filters: { mode: 'basic', status: 'open', assignee_type: 'all', calls_only: true }
      ).perform

      expect(snapshot.ids).to contain_exactly(
        mixed_mine_thread.display_id,
        unassigned_voice_thread.display_id,
        colleague_whatsapp_call_thread.display_id
      )
    end
  end
end
