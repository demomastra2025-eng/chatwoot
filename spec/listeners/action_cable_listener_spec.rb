require 'rails_helper'
describe ActionCableListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    Current.user = nil
    Current.account = nil
  end

  describe '#message_created' do
    let(:event_name) { :'message.created' }
    let!(:message) do
      create(:message, message_type: 'outgoing',
                       account: account, inbox: inbox, conversation: conversation)
    end
    let!(:event) { Events::Base.new(event_name, Time.zone.now, message: message) }

    it 'sends message to account admins, inbox agents and the contact' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.created',
        message.push_event_data.merge(account_id: account.id)
      )
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(conversation.contact_inbox.pubsub_token),
        'message.created',
        message.push_event_data(include_communication_thread: false).merge(account_id: account.id)
      )
      listener.message_created(event)
    end

    it 'sends message to all hmac verified contact inboxes' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      conversation.contact_inbox.update(hmac_verified: true)
      # creating a non verified contact inbox to ensure the events are not sent to it
      create(:contact_inbox, contact: conversation.contact, inbox: inbox)
      verified_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: inbox, hmac_verified: true)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.created',
        message.push_event_data.merge(account_id: account.id)
      )
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(conversation.contact_inbox.pubsub_token, verified_contact_inbox.pubsub_token),
        'message.created',
        message.push_event_data(include_communication_thread: false).merge(account_id: account.id)
      )
      listener.message_created(event)
    end

    it 'also broadcasts a dashboard-only communication thread refresh when the feature is enabled' do
      account.enable_features!('communication_threads')
      communication_thread = conversation.refresh_communication_thread!
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.created',
        message.push_event_data.merge(account_id: account.id)
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(conversation.contact_inbox.pubsub_token),
        'message.created',
        message.push_event_data(include_communication_thread: false).merge(account_id: account.id)
      )
      expected_payload = hash_including(
        account_id: account.id,
        id: communication_thread.display_id,
        communication_thread_id: communication_thread.display_id,
        is_communication_thread: true,
        source_event: 'message.created',
        message_id: message.id,
        conversation_id: conversation.display_id,
        conversation_ids: [conversation.display_id],
        contact_id: conversation.contact_id,
        inbox_id: inbox.id,
        channel: inbox.channel_type,
        status: communication_thread.reload.status,
        unread_count: communication_thread.unread_count
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [agent.pubsub_token],
        'communication_thread.updated',
        expected_payload
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [admin.pubsub_token],
        'communication_thread.updated',
        expected_payload
      )
    end

    it 'filters communication thread realtime payloads per recipient conversation permission scope' do
      account.enable_features!('communication_threads')
      communication_thread = conversation.refresh_communication_thread!
      contact = conversation.contact
      second_inbox = create(:inbox, account: account)
      second_agent = create(:user, account: account, role: :agent)
      second_contact_inbox = create(:contact_inbox, contact: contact, inbox: second_inbox)
      second_conversation = create(:conversation, account: account, contact: contact, inbox: second_inbox, contact_inbox: second_contact_inbox)
      create(:inbox_member, user: second_agent, inbox: second_inbox)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      listener.message_created(event)

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [agent.pubsub_token],
        'communication_thread.updated',
        hash_including(conversation_ids: [conversation.display_id])
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [admin.pubsub_token],
        'communication_thread.updated',
        hash_including(conversation_ids: contain_exactly(conversation.display_id, second_conversation.display_id))
      )
      expect(ActionCableBroadcastJob).not_to have_received(:perform_later).with(
        [second_agent.pubsub_token],
        'communication_thread.updated',
        anything
      )
      expect(communication_thread.communication_thread_conversations.count).to eq(2)
    end
  end

  describe '#typing_on' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    it 'sends message to account admins, inbox agents and the contact' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(
          admin.pubsub_token, conversation.contact_inbox.pubsub_token
        ),
        'conversation.typing_on', { conversation: conversation.push_event_data,
                                    user: agent.push_event_data,
                                    account_id: account.id,
                                    is_private: false }
      )
      listener.conversation_typing_on(event)
    end
  end

  describe '#typing_on with contact' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: conversation.contact, is_private: false) }

    it 'sends message to account admins, inbox agents and the contact' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(
          admin.pubsub_token, agent.pubsub_token
        ),
        'conversation.typing_on', { conversation: conversation.push_event_data,
                                    user: conversation.contact.push_event_data,
                                    account_id: account.id,
                                    is_private: false }
      )
      listener.conversation_typing_on(event)
    end
  end

  describe '#typing_on with agent bot' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:agent_bot) { create(:agent_bot, account: account) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent_bot, is_private: false) }

    it 'sends message to account admins, inbox agents and the contact' do
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(
          admin.pubsub_token, agent.pubsub_token, conversation.contact_inbox.pubsub_token
        ),
        'conversation.typing_on', { conversation: conversation.push_event_data,
                                    user: agent_bot.push_event_data,
                                    account_id: account.id,
                                    is_private: false }
      )
      listener.conversation_typing_on(event)
    end
  end

  describe '#typing_off' do
    let(:event_name) { :'conversation.typing_off' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    it 'sends message to account admins, inbox agents and the contact' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(
          admin.pubsub_token, conversation.contact_inbox.pubsub_token
        ),
        'conversation.typing_off', { conversation: conversation.push_event_data,
                                     user: agent.push_event_data,
                                     account_id: account.id,
                                     is_private: false }
      )
      listener.conversation_typing_off(event)
    end
  end

  describe '#contact_deleted' do
    let(:event_name) { :'contact.deleted' }
    let!(:contact) { create(:contact, account: account) }
    let(:contact_data) { contact.push_event_data.merge(account_id: contact.account_id) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, contact_data: contact_data) }

    it 'sends message to account admins, inbox agents' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        ["account_#{account.id}"],
        'contact.deleted',
        contact_data
      )
      listener.contact_deleted(event)
    end
  end

  describe '#notification_deleted' do
    let(:event_name) { :'notification.deleted' }
    let!(:notification) { create(:notification, account: account, user: agent) }
    let(:notification_data) do
      {
        id: notification.id,
        user_id: agent.id,
        account_id: account.id
      }
    end
    let!(:event) { Events::Base.new(event_name, Time.zone.now, notification_data: notification_data) }

    it 'sends message to account admins, inbox agents' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.deleted',
        {
          account_id: notification.account_id,
          notification: {
            id: notification.id
          },
          unread_count: 1,
          count: 1
        }
      )

      listener.notification_deleted(event)
    end
  end

  describe '#notification_updated' do
    let(:event_name) { :'notification.updated' }
    let!(:notification) { create(:notification, account: account, user: agent) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, notification: notification) }

    it 'sends notification to account admins, inbox agents' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.updated',
        {
          account_id: notification.account_id,
          notification: notification.push_event_data,
          unread_count: 1,
          count: 1
        }
      )

      listener.notification_updated(event)
    end
  end

  describe '#conversation_updated' do
    let(:event_name) { :'conversation.updated' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    before do
      conversation.add_labels(['support'])
    end

    it 'sends update to inbox members' do
      expect(conversation.inbox.reload.inbox_members.count).to eq(1)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token, admin.pubsub_token, conversation.contact_inbox.pubsub_token],
        'conversation.updated',
        conversation.push_event_data.merge(account_id: account.id)
      )
      listener.conversation_updated(event)
    end

    it 'broadcast event with label data' do
      expect(conversation.reload.push_event_data[:labels]).to eq(conversation.labels.pluck(:name))

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token, admin.pubsub_token, conversation.contact_inbox.pubsub_token],
        'conversation.updated',
        conversation.push_event_data.merge(account_id: account.id)
      )
      listener.conversation_updated(event)
    end
  end

  describe '#crm_deal_created' do
    let(:event_name) { :'crm.deal.created' }
    let(:pipeline) { create(:crm_pipeline, account: account) }
    let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
    let(:deal) { create(:crm_deal, account: account, pipeline: pipeline, stage: stage) }
    let(:event) do
      Events::Base.new(
        event_name,
        Time.zone.now,
        account: account,
        deal: deal,
        meta: { event_type: 'deal_created' }
      )
    end

    it 'broadcasts the deal payload to the account stream' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        ["account_#{account.id}"],
        'crm.deal.created',
        hash_including(
          account_id: account.id,
          deal: hash_including(id: deal.id, title: deal.title),
          meta: { event_type: 'deal_created' }
        )
      )

      listener.crm_deal_created(event)
    end
  end
end
