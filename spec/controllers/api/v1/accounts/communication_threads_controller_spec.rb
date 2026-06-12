# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Communication Threads API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }

  before do
    account.enable_features!('communication_threads')
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads' do
    def create_unread_thread_conversation(assignee: nil)
      conversation = create(
        :conversation,
        account: account,
        assignee: assignee,
        agent_last_seen_at: 1.day.ago
      )
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      create(
        :message,
        account: account,
        conversation: conversation,
        inbox: conversation.inbox,
        created_at: 1.minute.ago
      )
      conversation.reload.refresh_communication_thread!
      conversation
    end

    it 'returns unauthorized without auth' do
      get "/api/v1/accounts/#{account.id}/communication_threads", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns forbidden when the account feature flag is disabled' do
      account.disable_features!('communication_threads')

      get "/api/v1/accounts/#{account.id}/communication_threads", headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to eq('Communication threads feature is disabled')
    end

    it 'returns one thread for same-contact conversations across accessible inboxes' do
      contact = create(:contact, :with_email, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: contact, inbox: second_inbox)
      second_conversation = create(:conversation, account: account, contact: contact, inbox: second_inbox, contact_inbox: second_contact_inbox)
      message = create(:message, account: account, conversation: second_conversation, content: 'Latest from another channel')
      create(:inbox_member, user: agent, inbox: first_conversation.inbox)
      create(:inbox_member, user: agent, inbox: second_inbox)

      get "/api/v1/accounts/#{account.id}/communication_threads", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:data][:meta][:all_count]).to eq(1)
      thread_payload = body[:data][:payload].first
      expect(thread_payload[:id]).to eq(first_conversation.reload.communication_thread.display_id)
      expect(thread_payload[:messages].first[:id]).to eq(message.id)
      expect(thread_payload[:channels].pluck(:conversation_id)).to contain_exactly(first_conversation.display_id, second_conversation.display_id)
    end

    it 'does not expose inaccessible channel links inside an accessible thread' do
      contact = create(:contact, :with_email, account: account)
      accessible_conversation = create(:conversation, account: account, contact: contact)
      inaccessible_conversation = create(:conversation, account: account, contact: contact)
      create(:inbox_member, user: agent, inbox: accessible_conversation.inbox)

      get "/api/v1/accounts/#{account.id}/communication_threads", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      thread_payload = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload).first
      expect(thread_payload[:channels].pluck(:conversation_id)).to eq([accessible_conversation.display_id])
      expect(thread_payload[:channels].pluck(:conversation_id)).not_to include(inaccessible_conversation.display_id)
    end

    it 'filters threads by child conversation labels' do
      matching_conversation = create(:conversation, account: account)
      other_conversation = create(:conversation, account: account)
      matching_conversation.update_labels('vip')
      create(:inbox_member, user: agent, inbox: matching_conversation.inbox)
      create(:inbox_member, user: agent, inbox: other_conversation.inbox)

      get "/api/v1/accounts/#{account.id}/communication_threads",
          params: { labels: ['vip'] },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:success)
      payload = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload)
      expect(payload.pluck(:id)).to eq([matching_conversation.reload.communication_thread.display_id])
    end

    it 'filters by child conversation status and prefers the matching channel payload' do
      contact = create(:contact, account: account)
      inbox = create(:inbox, account: account)
      open_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      pending_contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      open_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: inbox,
        contact_inbox: open_contact_inbox,
        status: :open,
        updated_at: 2.minutes.ago
      )
      pending_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: inbox,
        contact_inbox: pending_contact_inbox,
        status: :pending
      )
      thread = pending_conversation.reload.communication_thread
      thread.update!(status: :open)
      create(:inbox_member, user: agent, inbox: inbox)

      get "/api/v1/accounts/#{account.id}/communication_threads",
          params: { status: 'pending' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:success)
      payload = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload)
      expect(payload.pluck(:id)).to eq([thread.display_id])
      expect(payload.first[:channels]).to contain_exactly(
        a_hash_including(
          conversation_id: pending_conversation.display_id,
          inbox_id: inbox.id,
          status: 'pending'
        )
      )
      expect(payload.first[:channels].pluck(:conversation_id)).not_to include(open_conversation.display_id)
    end

    it 'returns unread tab counts from meta independent of the current assignee tab page' do
      other_agent = create(:user, account: account, role: :agent)
      create_unread_thread_conversation(assignee: agent)
      create_unread_thread_conversation(assignee: other_agent)
      create_unread_thread_conversation

      get "/api/v1/accounts/#{account.id}/communication_threads",
          params: { status: 'open', assignee_type: 'me' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:success)
      meta = JSON.parse(response.body, symbolize_names: true).dig(:data, :meta)
      expect(meta).to include(
        mine_count: 1,
        assigned_count: 2,
        unassigned_count: 1,
        all_count: 3,
        mine_unread_count: 1,
        assigned_unread_count: 2,
        unassigned_unread_count: 1,
        all_unread_count: 3
      )
      payload = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload)
      expect(payload.size).to eq(1)

      get "/api/v1/accounts/#{account.id}/communication_threads/meta",
          params: { status: 'open' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['meta']).to include(
        'mine_unread_count' => 1,
        'unassigned_unread_count' => 1,
        'all_unread_count' => 3
      )
    end

    it 'sorts threads by supported sort options' do
      low_priority = create(:conversation, account: account, priority: :low)
      urgent_priority = create(:conversation, account: account, priority: :urgent)
      medium_priority = create(:conversation, account: account, priority: :medium)
      [low_priority, urgent_priority, medium_priority].each do |conversation|
        create(:inbox_member, user: agent, inbox: conversation.inbox)
      end

      get "/api/v1/accounts/#{account.id}/communication_threads",
          params: { status: 'all', sort_by: 'priority_desc' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:success)
      priorities = JSON.parse(response.body, symbolize_names: true).dig(:data, :payload).pluck(:priority)
      expect(priorities).to eq(%w[urgent medium low])
    end

    it 'rejects invalid list parameters instead of coercing them into SQL' do
      create(:conversation, account: account)

      get "/api/v1/accounts/#{account.id}/communication_threads",
          params: { status: 'invalid', sort_by: 'last_activity_at_desc;DROP' },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('Invalid communication thread')
    end
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads/:id/messages' do
    it 'returns a unified message timeline for accessible channel conversations', :aggregate_failures do
      contact = create(:contact, :with_email, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: contact, inbox: second_inbox)
      second_conversation = create(:conversation, account: account, contact: contact, inbox: second_inbox, contact_inbox: second_contact_inbox)
      first_message = create(:message, account: account, conversation: first_conversation, content: 'WhatsApp', created_at: 2.minutes.ago)
      second_message = create(:message, account: account, conversation: second_conversation, content: 'Telegram', created_at: 1.minute.ago)
      create(:inbox_member, user: agent, inbox: first_conversation.inbox)
      create(:inbox_member, user: agent, inbox: second_inbox)

      thread = first_conversation.reload.communication_thread
      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body[:payload].pluck(:id)).to eq([first_message.id, second_message.id])
      expect(body[:payload].pluck(:communication_thread_id)).to all(eq(thread.display_id))
      expect(body[:payload].pluck(:conversation_id)).to contain_exactly(first_conversation.display_id, second_conversation.display_id)
      expect(body[:payload].pluck(:inbox_id)).to contain_exactly(first_conversation.inbox_id, second_inbox.id)
      expect(body[:payload].pluck(:inbox_name)).to contain_exactly(first_conversation.inbox.name, second_inbox.name)
      expect(body[:payload].pluck(:channel)).to contain_exactly(first_conversation.inbox.channel_type, second_inbox.channel_type)
      expect(body[:payload].pluck(:contact_inbox_id)).to contain_exactly(first_conversation.contact_inbox_id, second_contact_inbox.id)
    end

    it 'uses timeline order for cursor pagination instead of raw message ids' do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      anchor = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, created_at: 2.minutes.ago)
      imported_older = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, created_at: 5.minutes.ago)
      later_message = create(:message, account: account, conversation: conversation, inbox: conversation.inbox, created_at: 1.minute.ago)
      thread = conversation.reload.communication_thread

      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
          params: { after: anchor.id },
          headers: headers,
          as: :json

      expect(response).to have_http_status(:success)
      message_ids = JSON.parse(response.body, symbolize_names: true)[:payload].pluck(:id)
      expect(message_ids).to eq([later_message.id])
      expect(message_ids).not_to include(imported_older.id)
    end

    it 'filters timeline messages by inbox access' do
      contact = create(:contact, :with_email, account: account)
      accessible_conversation = create(:conversation, account: account, contact: contact)
      inaccessible_conversation = create(:conversation, account: account, contact: contact)
      visible_message = create(:message, account: account, conversation: accessible_conversation, content: 'Visible')
      hidden_message = create(:message, account: account, conversation: inaccessible_conversation, content: 'Hidden')
      create(:inbox_member, user: agent, inbox: accessible_conversation.inbox)

      thread = accessible_conversation.reload.communication_thread
      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      message_ids = JSON.parse(response.body, symbolize_names: true)[:payload].pluck(:id)
      expect(message_ids).to eq([visible_message.id])
      expect(message_ids).not_to include(hidden_message.id)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/communication_threads/:id/update_last_seen' do
    it 'marks accessible linked conversations as read and refreshes the thread unread count' do
      contact = create(:contact, account: account)
      first_conversation = create(:conversation, account: account, contact: contact, agent_last_seen_at: 1.day.ago)
      second_inbox = create(:inbox, account: account)
      second_contact_inbox = create(:contact_inbox, contact: contact, inbox: second_inbox)
      second_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: second_inbox,
        contact_inbox: second_contact_inbox,
        agent_last_seen_at: 1.day.ago
      )
      create(:message, account: account, conversation: first_conversation, inbox: first_conversation.inbox, created_at: 2.minutes.ago)
      create(:message, account: account, conversation: second_conversation, inbox: second_inbox, created_at: 1.minute.ago)
      create(:inbox_member, user: agent, inbox: first_conversation.inbox)
      create(:inbox_member, user: agent, inbox: second_inbox)
      thread = first_conversation.reload.communication_thread

      expect(thread.reload.unread_count).to eq(2)

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/update_last_seen",
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      expect(first_conversation.reload.unread_incoming_messages_count).to eq(0)
      expect(second_conversation.reload.unread_incoming_messages_count).to eq(0)
      expect(thread.reload.unread_count).to eq(0)
      expect(response.parsed_body['unread_count']).to eq(0)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/communication_threads/:id/messages' do
    it 'sends through an existing linked child conversation', :aggregate_failures do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: { content: 'Reply from linked channel', conversation_id: conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body).to include(
        content: 'Reply from linked channel',
        communication_thread_id: thread.display_id,
        conversation_id: conversation.display_id,
        inbox_id: conversation.inbox_id,
        contact_inbox_id: conversation.contact_inbox_id
      )
      expect(body.dig(:communication_thread, :channels).pluck(:conversation_id)).to include(conversation.display_id)
      message = conversation.messages.outgoing.last
      expect(message.content).to eq('Reply from linked channel')
      expect(message.additional_attributes['delivery_policy']).to include(
        'allowed' => true,
        'delivery_mode' => 'free_text',
        'content_kind' => 'free_text'
      )
    end

    it 'keeps reauthorization as a warning while sending through a linked child conversation', :aggregate_failures do
      stub_request(:post, /graph.facebook.com/)
      facebook_channel = create(:channel_facebook_page, account: account)
      allow(facebook_channel).to receive(:send_channel_reauthorization_email)
      facebook_inbox = create(:inbox, account: account, channel: facebook_channel)
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: facebook_inbox)
      conversation = create(:conversation, account: account, contact: contact, inbox: facebook_inbox, contact_inbox: contact_inbox)
      create(:message, account: account, inbox: facebook_inbox, conversation: conversation, message_type: 'incoming')
      create(:inbox_member, user: agent, inbox: facebook_inbox)
      facebook_channel.prompt_reauthorization!
      thread = conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: { content: 'Reply despite auth warning', conversation_id: conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      message = conversation.messages.outgoing.last
      channel_payload = body.dig(:communication_thread, :channels).find { |channel| channel[:conversation_id] == conversation.display_id }

      expect(message.content).to eq('Reply despite auth warning')
      expect(channel_payload).to include(
        reauthorization_required: true,
        can_send_text: true,
        disabled: false,
        disabled_reason: nil
      )
    end

    it 'evaluates delivery policy instead of trusting caller-provided metadata' do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: {
             content: 'Reply with policy metadata',
             conversation_id: conversation.display_id,
             delivery_policy: { delivery_mode: 'bypass' }
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      delivery_policy = conversation.messages.outgoing.last.additional_attributes['delivery_policy']
      expect(delivery_policy).to include('allowed' => true, 'delivery_mode' => 'free_text')
      expect(delivery_policy).not_to include('delivery_mode' => 'bypass')
    end

    it 'rejects public text delivery through voice call channels' do
      contact = create(:contact, phone_number: '+15550001234', account: account)
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox)
      conversation = create(:conversation, account: account, contact: contact, inbox: voice_inbox, contact_inbox: contact_inbox)
      create(:inbox_member, user: agent, inbox: voice_inbox)
      thread = conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: { content: 'Do not send text into a call channel', conversation_id: conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('voice_call_only')
      expect(conversation.messages.outgoing).to be_empty
    end

    it 'allows private notes while a voice call channel is selected' do
      contact = create(:contact, phone_number: '+15550001234', account: account)
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
      contact_inbox = create(:contact_inbox, contact: contact, inbox: voice_inbox)
      conversation = create(:conversation, account: account, contact: contact, inbox: voice_inbox, contact_inbox: contact_inbox)
      create(:inbox_member, user: agent, inbox: voice_inbox)
      thread = conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: { content: 'Call note', conversation_id: conversation.display_id, private: true },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      expect(conversation.messages.outgoing.last).to have_attributes(content: 'Call note', private: true)
    end

    it 'rejects a linked child conversation hidden by the native conversation permission scope' do
      contact = create(:contact, :with_email, account: account)
      visible_conversation = create(:conversation, account: account, contact: contact, assignee: agent)
      hidden_inbox = create(:inbox, account: account)
      hidden_contact_inbox = create(:contact_inbox, contact: contact, inbox: hidden_inbox)
      hidden_conversation = create(:conversation, account: account, contact: contact, inbox: hidden_inbox, contact_inbox: hidden_contact_inbox)
      custom_role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
      agent.account_users.find_by(account: account).update!(custom_role: custom_role)
      create(:inbox_member, user: agent, inbox: visible_conversation.inbox)
      create(:inbox_member, user: agent, inbox: hidden_inbox)
      thread = visible_conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: { content: 'Do not send', conversation_id: hidden_conversation.display_id },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:not_found)
      expect(hidden_conversation.messages.outgoing).to be_empty
    end

    it 'keeps JSON multipart metadata for attachments and templates', :aggregate_failures do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread
      file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: {
             content: 'Reply with attachment metadata',
             conversation_id: conversation.display_id,
             attachments: [file],
             content_attributes: { voice_note: true }.to_json,
             template_params: { name: 'follow_up', language: 'ru', processed_params: { body: { '1': 'Ahan' } } }.to_json,
             delivery_policy: { delivery_mode: 'free_text' }.to_json
           },
           headers: headers

      expect(response).to have_http_status(:success)
      message = conversation.messages.outgoing.last
      expect(message.content_attributes).to include('voice_note' => true)
      expect(message.additional_attributes['template_params']).to include('name' => 'follow_up', 'language' => 'ru')
      expect(message.additional_attributes.dig('template_params', 'processed_params', 'body')).to include('1' => 'Ahan')
      expect(message.additional_attributes['delivery_policy']).to include('delivery_mode' => 'free_text')
      expect(message.attachments).to be_present
    end

    it 'creates and links a child conversation for an unlinked selected contact inbox', :aggregate_failures do
      contact = create(:contact, :with_email, account: account)
      existing_conversation = create(:conversation, account: account, contact: contact)
      target_inbox = create(:inbox, account: account)
      target_contact_inbox = create(:contact_inbox, contact: contact, inbox: target_inbox)
      create(:inbox_member, user: agent, inbox: existing_conversation.inbox)
      create(:inbox_member, user: agent, inbox: target_inbox)
      thread = existing_conversation.reload.communication_thread

      expect do
        post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
             params: {
               content: 'Reply from new channel',
               channel_key: "inbox:#{target_inbox.id}",
               target_contact_inbox_id: target_contact_inbox.id
             },
             headers: headers,
             as: :json
      end.to change(Conversation, :count).by(1)

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      created_conversation = Conversation.find_by!(display_id: body[:conversation_id], account_id: account.id)
      expect(created_conversation).to have_attributes(
        contact_id: contact.id,
        inbox_id: target_inbox.id,
        contact_inbox_id: target_contact_inbox.id
      )
      expect(created_conversation.communication_thread).to eq(thread)
      expect(body).to include(
        content: 'Reply from new channel',
        communication_thread_id: thread.display_id,
        inbox_id: target_inbox.id,
        contact_inbox_id: target_contact_inbox.id
      )
      expect(body.dig(:communication_thread, :conversation_ids)).to include(created_conversation.display_id)
      expect(body.dig(:communication_thread, :channels).pluck(:channel_key)).to include("conversation:#{created_conversation.display_id}")
    end

    it 'rejects a target contact inbox from another contact' do
      conversation = create(:conversation, account: account)
      target_inbox = create(:inbox, account: account)
      other_contact_inbox = create(:contact_inbox, inbox: target_inbox)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      create(:inbox_member, user: agent, inbox: target_inbox)
      thread = conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: {
             content: 'Nope',
             channel_key: "inbox:#{target_inbox.id}",
             target_contact_inbox_id: other_contact_inbox.id
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads/:id/channels' do
    it 'returns capability metadata for accessible child conversations' do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread

      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/channels", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      channel_payload = JSON.parse(response.body, symbolize_names: true).dig(:payload, 0)
      expect(channel_payload).to include(
        conversation_id: conversation.display_id,
        inbox_id: conversation.inbox_id,
        can_reply: conversation.can_reply?,
        can_send_text: conversation.can_reply?,
        disabled: !conversation.can_reply?
      )
    end

    it 'returns linked channels and supported unlinked contact channels' do
      contact = create(:contact, :with_email, account: account)
      inbox = create(:inbox, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: inbox)
      older_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: inbox,
        contact_inbox: contact_inbox,
        last_activity_at: 2.days.ago
      )
      newer_conversation = create(
        :conversation,
        account: account,
        contact: contact,
        inbox: inbox,
        contact_inbox: contact_inbox,
        last_activity_at: 1.hour.ago
      )
      unlinked_inbox = create(:inbox, :with_email, account: account)
      create(:contact_inbox, contact: contact, inbox: unlinked_inbox)
      create(:inbox_member, user: agent, inbox: inbox)
      create(:inbox_member, user: agent, inbox: unlinked_inbox)
      thread = older_conversation.reload.communication_thread

      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/channels", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      channels = JSON.parse(response.body, symbolize_names: true).fetch(:payload)
      expect(channels.pluck(:inbox_id)).to contain_exactly(inbox.id, unlinked_inbox.id)
      expect(channels.find { |channel| channel[:inbox_id] == inbox.id }[:conversation_id]).to eq(newer_conversation.display_id)
      expect(channels.find { |channel| channel[:inbox_id] == unlinked_inbox.id }).to include(
        conversation_id: nil,
        can_send_text: true,
        disabled: false,
        channel_key: "inbox:#{unlinked_inbox.id}"
      )
    end
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads/:id/attachments' do
    it 'returns attachments from linked child conversations through the thread endpoint' do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread
      file = fixture_file_upload(Rails.root.join('spec/assets/avatar.png'), 'image/png')

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/messages",
           params: { content: 'Reply with attachment', conversation_id: conversation.display_id, attachments: [file] },
           headers: headers

      expect(response).to have_http_status(:success)
      attachment = conversation.messages.outgoing.last.attachments.first

      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/attachments", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body.dig(:meta, :total_count)).to eq(1)
      expect(body[:payload].pluck(:id)).to eq([attachment.id])
    end
  end

  describe 'GET /api/v1/accounts/:account_id/communication_threads/:id/labels' do
    it 'returns the deduplicated label set from accessible child conversations' do
      contact = create(:contact, :with_email, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      hidden_conversation = create(:conversation, account: account, contact: contact)
      first_conversation.update_labels(%w[vip billing])
      second_conversation.update_labels(%w[vip follow_up])
      hidden_conversation.update_labels(%w[hidden])
      create(:inbox_member, user: agent, inbox: first_conversation.inbox)
      create(:inbox_member, user: agent, inbox: second_conversation.inbox)
      thread = first_conversation.reload.communication_thread

      get "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/labels", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload']).to contain_exactly('vip', 'billing', 'follow_up')
    end
  end

  describe 'POST /api/v1/accounts/:account_id/communication_threads/:id/labels' do
    it 'updates labels on all accessible linked child conversations' do
      contact = create(:contact, :with_email, account: account)
      first_conversation = create(:conversation, account: account, contact: contact)
      second_conversation = create(:conversation, account: account, contact: contact)
      create(:inbox_member, user: agent, inbox: first_conversation.inbox)
      create(:inbox_member, user: agent, inbox: second_conversation.inbox)
      thread = first_conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/labels",
           params: { labels: %w[vip paid] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['payload']).to eq(%w[vip paid])
      expect(first_conversation.reload.label_list).to contain_exactly('vip', 'paid')
      expect(second_conversation.reload.label_list).to contain_exactly('vip', 'paid')
    end

    it 'updates labels only on accessible linked child conversations when the thread has hidden channels' do
      contact = create(:contact, :with_email, account: account)
      accessible_conversation = create(:conversation, account: account, contact: contact)
      inaccessible_conversation = create(:conversation, account: account, contact: contact)
      inaccessible_conversation.update_labels(%w[hidden])
      create(:inbox_member, user: agent, inbox: accessible_conversation.inbox)
      thread = accessible_conversation.reload.communication_thread

      post "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}/labels",
           params: { labels: %w[vip paid] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      expect(accessible_conversation.reload.label_list).to contain_exactly('vip', 'paid')
      expect(inaccessible_conversation.reload.label_list).to contain_exactly('hidden')
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/communication_threads/:id' do
    it 'updates status, priority, assignee and team on accessible child conversations' do
      team = create(:team, account: account)
      create(:team_member, user: agent, team: team)
      assignee = create(:user, account: account)
      create(:team_member, user: assignee, team: team)
      conversation = create(:conversation, account: account, status: :open, priority: :low)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread

      patch "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}",
            params: { status: 'pending', priority: 'urgent', assignee_id: assignee.id, team_id: team.id },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:success)
      body = JSON.parse(response.body, symbolize_names: true)
      expect(body).to include(status: 'pending', priority: 'urgent', assignee_id: assignee.id, team_id: team.id)
      expect(conversation.reload).to have_attributes(status: 'pending', priority: 'urgent', assignee_id: assignee.id, team_id: team.id)
    end

    it 'rejects updates when the agent cannot access every linked channel' do
      contact = create(:contact, :with_email, account: account)
      accessible_conversation = create(:conversation, account: account, contact: contact, status: :open)
      inaccessible_conversation = create(:conversation, account: account, contact: contact, status: :open)
      create(:inbox_member, user: agent, inbox: accessible_conversation.inbox)
      thread = accessible_conversation.reload.communication_thread

      patch "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}",
            params: { status: 'resolved' },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('without access to all linked channels')
      expect(accessible_conversation.reload).to be_open
      expect(inaccessible_conversation.reload).to be_open
      expect(thread.reload).to be_open
    end

    it 'rejects invalid agent bot assignments' do
      conversation = create(:conversation, account: account)
      create(:inbox_member, user: agent, inbox: conversation.inbox)
      thread = conversation.reload.communication_thread

      patch "/api/v1/accounts/#{account.id}/communication_threads/#{thread.display_id}",
            params: { assignee_id: -1, assignee_type: 'AgentBot' },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('Invalid communication thread assignee_id')
    end
  end
end
