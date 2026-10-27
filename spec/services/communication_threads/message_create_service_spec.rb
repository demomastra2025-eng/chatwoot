# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::MessageCreateService do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:api_inbox) { create(:channel_api, account: account).inbox }
  let(:dispatcher) { Rails.configuration.dispatcher }
  let(:events) { [] }

  before do
    create(:inbox_member, user: agent, inbox: api_inbox)
    allow(dispatcher).to receive(:dispatch).and_wrap_original do |original, event, *args|
      events << event
      original.call(event, *args)
    end
  end

  def build_service(params, user: agent, target: contact)
    described_class.new(
      contact: target,
      current_user: user,
      params: ActionController::Parameters.new(params),
      accessible_inboxes: account.inboxes.where(id: user.inboxes.select(:id)),
      accessible_conversations: Conversations::PermissionFilterService.new(account.conversations, user, account).perform
    )
  end

  def start_params(**overrides)
    { channel_key: "inbox:#{api_inbox.id}", content: 'Hello', echo_id: SecureRandom.uuid }.merge(overrides)
  end

  describe 'the first message of a person without a dialog' do
    it 'starts the dialog without announcing a new conversation', :aggregate_failures do
      expect { build_service(start_params).perform }.to change(Conversation, :count).by(1).and change(CommunicationThread, :count).by(1)

      expect(events).not_to include(Events::Types::CONVERSATION_CREATED, Events::Types::ASSIGNEE_CHANGED)
      expect(events).to include(Events::Types::MESSAGE_CREATED)
      expect(Notification.count).to eq(0)
    end

    it 'adds no assignment activity line to the conversation' do
      service = build_service(start_params)
      service.perform

      expect(service.conversation.messages.activity).to be_empty
    end

    it 'does not leak the silence into the later updates of the conversation', :aggregate_failures do
      service = build_service(start_params)
      service.perform

      expect(service.conversation.skip_runtime_events).to be_falsey
      events.clear
      service.conversation.update!(priority: :high)

      expect(events).to include(Events::Types::CONVERSATION_UPDATED)
    end

    it 'assigns the dialog to the owner of the person', :aggregate_failures do
      owner = create(:user, account: account, role: :agent)
      contact.update!(owner: owner)

      service = build_service(start_params)
      service.perform

      expect(service.conversation.assignee).to eq(owner)
      expect(contact.reload.owner).to eq(owner)
    end

    it 'assigns the dialog to the sender when the person has no owner', :aggregate_failures do
      service = build_service(start_params)
      service.perform

      expect(service.conversation.assignee).to eq(agent)
      expect(service.communication_thread).to have_attributes(contact_id: contact.id, assignee_id: agent.id, status: 'open')
      expect(service.communication_thread.conversations).to contain_exactly(service.conversation)
    end

    it 'leaves nothing behind when the send is refused', :aggregate_failures do
      whatsapp_inbox = create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false).inbox
      create(:inbox_member, user: agent, inbox: whatsapp_inbox)
      service = build_service(start_params(channel_key: "inbox:#{whatsapp_inbox.id}"))

      expect { service.perform }.to raise_error(described_class::Error) { |error| expect(error.code).to eq('template_required') }
      expect([ContactInbox.count, Conversation.count, CommunicationThread.count, Message.count]).to eq([0, 0, 0, 0])
    end

    it 'starts the dialog with a private note' do
      service = build_service(start_params(content: 'Remember the insurance', private: true))

      expect { service.perform }.to change(Conversation, :count).by(1)
      expect(service.message).to have_attributes(private: true, content: 'Remember the insurance')
    end
  end

  describe 'the message of a person who has a dialog' do
    let!(:existing) do
      other_inbox = create(:channel_api, account: account).inbox
      create(:inbox_member, user: agent, inbox: other_inbox)
      create(:conversation, account: account, contact: contact, inbox: other_inbox,
                            contact_inbox: create(:contact_inbox, contact: contact, inbox: other_inbox), assignee: agent, priority: :low)
    end

    before { events.clear }

    it 'sends into a linked conversation by its channel key', :aggregate_failures do
      service = build_service({ channel_key: "conversation:#{existing.display_id}", content: 'Reply' })

      expect { service.perform }.not_to change(Conversation, :count)
      expect(service.message).to have_attributes(conversation_id: existing.id, content: 'Reply')
    end

    it 'joins the new channel to the thread with the status, assignee, team and priority of the dialog', :aggregate_failures do
      thread = existing.reload.communication_thread
      service = build_service(start_params)

      expect { service.perform }.to change(Conversation, :count).by(1)

      expect(service.communication_thread).to eq(thread)
      expect(service.conversation).to have_attributes(assignee_id: agent.id, priority: 'low', status: 'open')
      expect(thread.conversations).to include(service.conversation)
      expect(events).not_to include(Events::Types::CONVERSATION_CREATED)
    end

    it 'does not take a message from a conversation hidden from the user' do
      hidden_inbox = create(:channel_api, account: account).inbox
      InboxMember.where(user: agent, inbox: hidden_inbox).delete_all
      hidden = create(:conversation, account: account, contact: contact, inbox: hidden_inbox,
                                     contact_inbox: create(:contact_inbox, contact: contact, inbox: hidden_inbox))

      service = build_service({ channel_key: "conversation:#{hidden.display_id}", content: 'No' })

      expect { service.perform }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe 'a key sent twice' do
    it 'answers the second send with the message of the first', :aggregate_failures do
      params = start_params
      first = build_service(params)
      first_message = first.perform

      second = build_service(params.merge(content: 'Hello again'))

      expect { second.perform }.not_to change(Message, :count)
      expect(second.message).to eq(first_message)
      expect(second.communication_thread).to eq(first.communication_thread)
    end

    it 'does not take a key of another person' do
      other = create(:contact, account: account, phone_number: '+77010000002')
      key = SecureRandom.uuid
      build_service(start_params(echo_id: key), target: other).perform

      expect { build_service(start_params(echo_id: key)).perform }.to change(Message, :count).by(1)
    end

    it 'forgets a key after a day' do
      key = SecureRandom.uuid
      first = build_service(start_params(echo_id: key))
      first.perform
      first.message.update_columns(created_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations

      expect { build_service(start_params(echo_id: key)).perform }.to change(Message, :count).by(1)
    end
  end
end
