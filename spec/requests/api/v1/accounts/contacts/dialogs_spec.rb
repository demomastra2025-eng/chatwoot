# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Contact dialog API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:whatsapp_channel) { create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false) }
  let(:whatsapp_inbox) { whatsapp_channel.inbox }
  let(:template_params) do
    {
      name: 'sample_shipping_confirmation',
      language: 'en_US',
      namespace: '23423423_2342423_324234234_2343224',
      processed_params: { body: { '1' => '2' } }
    }
  end

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: agent, inbox: whatsapp_inbox)
  end

  def row_counts
    {
      contact_inboxes: ContactInbox.count,
      conversations: Conversation.count,
      threads: CommunicationThread.count,
      links: CommunicationThreadConversation.count,
      messages: Message.count
    }
  end

  def row_deltas(before_counts)
    row_counts.to_h { |key, count| [key, count - before_counts.fetch(key)] }
  end

  # Every user of the account is a member of every inbox when the inbox is made; an inbox the agent does not work in is one he
  # was removed from.
  def inbox_without_agent
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox.tap do |inbox|
      InboxMember.where(user: agent, inbox: inbox).delete_all
    end
  end

  def dialog_path(target = contact)
    "/api/v1/accounts/#{account.id}/contacts/#{target.id}/dialog"
  end

  def post_message(params, target: contact)
    post "#{dialog_path(target)}/messages", params: params, headers: headers, as: :json
  end

  describe 'GET /api/v1/accounts/:account_id/contacts/:id/dialog' do
    it 'requires authentication' do
      get dialog_path, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'is forbidden while the communication threads feature is off' do
      account.disable_features!('communication_threads')

      get dialog_path, headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'answers a person without a dialog with a draft and writes nothing', :aggregate_failures do
      whatsapp_inbox
      before_counts = row_counts

      get dialog_path, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      body = response.parsed_body
      expect(body['communication_thread_id']).to be_nil
      expect(body['contact']).to include('id' => contact.id, 'phone_number' => '+77011234567')
      expect(body['blocked']).to be(false)
      expect(body['shared_phone_holder']).to be_nil
      whatsapp = body['channels'].find { |channel| channel['inbox_id'] == whatsapp_inbox.id }
      expect(whatsapp).to include(
        'conversation_id' => nil, 'channel_key' => "inbox:#{whatsapp_inbox.id}", 'requires_template' => true, 'can_send_text' => false
      )
      expect(row_counts).to eq(before_counts)
    end

    it 'answers a person who has a dialog with the id of the thread only' do
      conversation = create(:conversation, account: account, contact: contact, inbox: whatsapp_inbox,
                                           contact_inbox: create(:contact_inbox, contact: contact, inbox: whatsapp_inbox))
      thread = conversation.reload.communication_thread

      get dialog_path, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq('communication_thread_id' => thread.display_id)
    end

    it 'offers reachable reply channels for an existing dialog when requested' do
      conversation = create(:conversation, account: account, contact: contact, inbox: whatsapp_inbox,
                                           contact_inbox: create(:contact_inbox, contact: contact, inbox: whatsapp_inbox))
      thread = conversation.reload.communication_thread
      second_channel = create(
        :channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false
      )
      second_inbox = second_channel.inbox

      get dialog_path, params: { include_reply_channels: true }, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      body = response.parsed_body
      expect(body['communication_thread_id']).to eq(thread.display_id)
      expect(body['channels'].pluck('inbox_id')).to include(whatsapp_inbox.id, second_inbox.id)
      expect(body['channels'].find { |channel| channel['inbox_id'] == second_inbox.id }).to include(
        'channel_key' => "inbox:#{second_inbox.id}", 'requires_template' => true
      )
    end

    it 'offers an agent only the channels of the inboxes the agent works in', :aggregate_failures do
      other_inbox = inbox_without_agent

      get dialog_path, headers: headers, as: :json

      inbox_ids = response.parsed_body['channels'].pluck('inbox_id')
      expect(inbox_ids).to include(whatsapp_inbox.id)
      expect(inbox_ids).not_to include(other_inbox.id)
    end

    it 'treats a thread the agent cannot open as no thread' do
      hidden_inbox = inbox_without_agent
      hidden_contact_inbox = create(:contact_inbox, contact: contact, inbox: hidden_inbox)
      create(:conversation, account: account, contact: contact, inbox: hidden_inbox, contact_inbox: hidden_contact_inbox)
      expect(CommunicationThread.where(contact_id: contact.id).count).to eq(1)

      get dialog_path, headers: headers, as: :json

      expect(response.parsed_body['communication_thread_id']).to be_nil
      expect(response.parsed_body['channels'].pluck('inbox_id')).to include(whatsapp_inbox.id)
    end

    it 'names the holder of the number for a card without a number of its own', :aggregate_failures do
      holder = create(:contact, account: account, name: 'Aigul', phone_number: '+77010000001')
      child = create(:contact, account: account, name: 'Child', phone_number: nil)
      attributes = Contacts::SharedPhone.record_share!(child.custom_attributes.to_h, phone: holder.phone_number, owner_id: holder.id,
                                                                                     via: Contacts::SharedPhone::VIA_OWNER_PRIMARY)
      child.update!(custom_attributes: attributes)

      get dialog_path(child), headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['shared_phone_holder']).to eq('id' => holder.id, 'name' => 'Aigul')
    end

    it 'lists the WhatsApp of a card without a number as disabled and asking for no template', :aggregate_failures do
      child = create(:contact, account: account, name: 'Child', phone_number: nil)

      get dialog_path(child), headers: headers, as: :json

      whatsapp = response.parsed_body['channels'].find { |channel| channel['inbox_id'] == whatsapp_inbox.id }
      expect(whatsapp).to include(
        'requires_template' => false, 'can_reply' => false, 'can_send_text' => false,
        'disabled' => true, 'disabled_reason' => 'missing_contact_phone_number'
      )
    end

    it 'does not offer a Telegram bot to a person who never wrote to it, with a Telegram id or without', :aggregate_failures do
      telegram_inbox = create(:channel_telegram, account: account).inbox
      create(:inbox_member, user: agent, inbox: telegram_inbox)
      contact.update!(additional_attributes: { 'social_telegram_user_id' => '555000111' })

      get dialog_path, headers: headers, as: :json

      expect(response.parsed_body['channels'].pluck('inbox_id')).not_to include(telegram_inbox.id)
    end

    it 'reports a blocked contact' do
      contact.update!(blocked: true)

      get dialog_path, headers: headers, as: :json

      expect(response.parsed_body['blocked']).to be(true)
    end

    it 'does not find a contact of another account' do
      other_contact = create(:contact, account: create(:account))

      get "/api/v1/accounts/#{account.id}/contacts/#{other_contact.id}/dialog", headers: headers, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/accounts/:account_id/contacts/:id/dialog/messages' do
    let(:echo_id) { SecureRandom.uuid }

    def start_params(**overrides)
      { channel_key: "inbox:#{whatsapp_inbox.id}", echo_id: echo_id, template_params: template_params,
        content: 'Shipping update: 2' }.merge(overrides)
    end

    it 'refuses free text on the closed WhatsApp window and leaves no row behind', :aggregate_failures do
      before_counts = row_counts

      post_message(start_params(template_params: nil, content: 'Hello'))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'template_required')
      expect(row_counts).to eq(before_counts)
    end

    it 'starts the dialog with an approved template and sends it', :aggregate_failures do
      before_counts = row_counts
      expect { post_message(start_params) }.to change(Message, :count).by(1)

      expect(response).to have_http_status(:success)
      expect(row_deltas(before_counts)).to include(contact_inboxes: 1, conversations: 1, threads: 1, links: 1, messages: 1)
      body = response.parsed_body
      message = Message.last
      expect(message).to have_attributes(content: 'Shipping update: 2', message_type: 'outgoing', sender_id: agent.id)
      expect(message.additional_attributes).to include('echo_id' => echo_id)
      expect(message.additional_attributes.dig('delivery_policy', 'delivery_mode')).to eq('channel_template')
      expect(body['communication_thread_id']).to eq(CommunicationThread.last.display_id)
      expect(body['conversation_id']).to eq(message.conversation.display_id)
      expect(body.dig('communication_thread', 'channels').pluck('channel_key')).to include("conversation:#{message.conversation.display_id}")
      expect(message.conversation).to have_attributes(contact_id: contact.id, inbox_id: whatsapp_inbox.id, status: 'open')
      expect(SendReplyJob).to have_been_enqueued.with(message.id)
      expect(ContactInbox.last).to have_attributes(contact_id: contact.id, inbox_id: whatsapp_inbox.id, source_id: '77011234567')
    end

    it 'answers the same echo_id with the same message', :aggregate_failures do
      post_message(start_params)
      first_message_id = response.parsed_body['id']
      before_counts = row_counts

      post_message(start_params)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(first_message_id)
      expect(row_counts).to eq(before_counts)
    end

    it 'puts two different sends into one conversation and one thread', :aggregate_failures do
      before_counts = row_counts
      post_message(start_params)
      post_message(start_params(echo_id: SecureRandom.uuid, content: 'Second'))

      expect(response).to have_http_status(:success)
      expect(row_deltas(before_counts)).to include(conversations: 1, threads: 1, links: 1, messages: 2)
    end

    it 'puts the sends of two staff members for the same person into one dialog', :aggregate_failures do
      colleague = create(:user, account: account, role: :agent)
      create(:inbox_member, user: colleague, inbox: whatsapp_inbox)
      before_counts = row_counts

      post_message(start_params)
      post "#{dialog_path}/messages", params: start_params(echo_id: SecureRandom.uuid), headers: colleague.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(row_deltas(before_counts)).to include(conversations: 1, threads: 1, messages: 2)
    end

    it 'joins the thread of a person who has a dialog in another channel', :aggregate_failures do
      other_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      create(:inbox_member, user: agent, inbox: other_inbox)
      existing = create(:conversation, account: account, contact: contact, inbox: other_inbox,
                                       contact_inbox: create(:contact_inbox, contact: contact, inbox: other_inbox))
      thread = existing.reload.communication_thread
      before_counts = row_counts

      post_message(start_params)

      expect(response).to have_http_status(:success)
      expect(row_deltas(before_counts)).to include(threads: 0, conversations: 1, links: 1)
      expect(response.parsed_body['communication_thread_id']).to eq(thread.display_id)
    end

    it 'keeps the other contact untouched when the chat identity belongs to another contact', :aggregate_failures do
      other = create(:contact, account: account, phone_number: '+77019999999')
      foreign = create(:contact_inbox, contact: other, inbox: whatsapp_inbox, source_id: '77011234567')
      before_counts = row_counts

      post_message(start_params)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'foreign_chat_identity', 'details' => { 'contact_name' => other.display_full_name })
      expect(row_counts).to eq(before_counts)
      expect(foreign.reload).to have_attributes(contact_id: other.id, source_id: '77011234567')
    end

    it 'requires the echo_id' do
      before_counts = row_counts

      post_message(start_params.except(:echo_id))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'echo_id_required')
      expect(row_counts).to eq(before_counts)
    end

    it 'refuses to start a dialog with a blocked contact' do
      contact.update!(blocked: true)
      before_counts = row_counts

      post_message(start_params)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'contact_blocked')
      expect(row_counts).to eq(before_counts)
    end

    it 'refuses a channel the agent does not work in' do
      other_inbox = inbox_without_agent
      before_counts = row_counts

      post_message(start_params(channel_key: "inbox:#{other_inbox.id}"))

      expect(response).to have_http_status(:not_found)
      expect(row_counts).to eq(before_counts)
    end

    it 'refuses a channel the person cannot be reached on' do
      contact.update!(phone_number: nil)
      before_counts = row_counts

      post_message(start_params)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'channel_unavailable')
      expect(row_counts).to eq(before_counts)
    end

    context 'with a Telegram bot' do
      let(:telegram_inbox) { create(:channel_telegram, account: account).inbox }

      before do
        create(:inbox_member, user: agent, inbox: telegram_inbox)
        contact.update!(additional_attributes: { 'social_telegram_user_id' => '555000111' })
      end

      it 'does not write first to a person who never wrote to the bot, and leaves no row behind', :aggregate_failures do
        before_counts = row_counts

        post_message({ channel_key: "inbox:#{telegram_inbox.id}", echo_id: echo_id, content: 'Hello from the clinic' })

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to include('code' => 'channel_unavailable')
        expect(row_counts).to eq(before_counts)
      end

      it 'writes to a person who has written to the bot, by their Telegram id', :aggregate_failures do
        create(:contact_inbox, contact: contact, inbox: telegram_inbox, source_id: '555000111')

        post_message({ channel_key: "inbox:#{telegram_inbox.id}", echo_id: echo_id, content: 'Hello from the clinic' })

        expect(response).to have_http_status(:success)
        expect(Message.last.conversation.additional_attributes).to include('chat_id' => '555000111')
      end
    end

    it 'puts the send into the conversation the dialog got in that inbox a moment ago, whatever the inbox setting', :aggregate_failures do
      whatsapp_inbox.update!(lock_to_single_conversation: false)
      before_counts = row_counts

      post_message(start_params)
      post_message(start_params(echo_id: SecureRandom.uuid, content: 'Second'))

      expect(response).to have_http_status(:success)
      expect(row_deltas(before_counts)).to include(conversations: 1, threads: 1, links: 1, messages: 2)
    end

    it 'does not start a conversation in a bot or AI status: it is open and nobody waits for a reply', :aggregate_failures do
      create(:integrations_hook, :dialogflow, account: account, inbox: whatsapp_inbox)

      post_message(start_params)

      conversation = Message.last.conversation
      expect(conversation).to have_attributes(status: 'open', waiting_since: nil)
    end

    it 'says there is no channel for a note when the screen has none to name', :aggregate_failures do
      before_counts = row_counts

      post_message({ echo_id: echo_id, content: 'Remember', private: true })

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include('code' => 'no_reachable_channel')
      expect(row_counts).to eq(before_counts)
    end

    it 'starts the dialog with a private note on the empty screen', :aggregate_failures do
      before_counts = row_counts
      post_message({ channel_key: "inbox:#{whatsapp_inbox.id}", echo_id: echo_id, content: 'Call back after 18:00', private: true })

      expect(response).to have_http_status(:success)
      expect(row_deltas(before_counts)).to include(conversations: 1, threads: 1, messages: 1)
      expect(Message.last).to have_attributes(content: 'Call back after 18:00', private: true)
    end
  end
end
