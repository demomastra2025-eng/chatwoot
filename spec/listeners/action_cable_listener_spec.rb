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
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent, message.sender)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
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

    it 'uses the dedicated realtime queue for voice-call messages' do
      message.update!(content_type: :voice_call)
      configured_job = instance_double(ActiveJob::ConfiguredJob)

      expect(ActionCableBroadcastJob).to receive(:set).with(queue: :telephony_realtime).twice.and_return(configured_job)
      expect(configured_job).to receive(:perform_later).twice

      listener.message_created(event)
    end

    it 'sends message to all hmac verified contact inboxes' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent, message.sender)
      conversation.contact_inbox.update(hmac_verified: true)
      # creating a non verified contact inbox to ensure the events are not sent to it
      create(:contact_inbox, contact: conversation.contact, inbox: inbox)
      verified_contact_inbox = create(:contact_inbox, contact: conversation.contact, inbox: inbox, hmac_verified: true)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
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
      perform_communication_thread_realtime { listener.message_created(event) }

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
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
        channels: [hash_including(
          conversation_id: conversation.display_id,
          inbox_id: inbox.id,
          channel: inbox.channel_type,
          channel_key: "conversation:#{conversation.display_id}"
        )],
        contact_id: conversation.contact_id,
        meta: hash_including(
          sender: hash_including(id: conversation.contact_id),
          channel: 'CommunicationThread'
        ),
        inbox_id: inbox.id,
        channel: inbox.channel_type,
        status: communication_thread.reload.status,
        unread_count: communication_thread.unread_count
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
        'communication_thread.updated',
        expected_payload
      )
    end

    it 'broadcasts directional message timestamps in communication thread updates' do
      account.enable_features!('communication_threads')
      communication_thread = conversation.refresh_communication_thread!
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
      incoming_message = create(
        :message,
        account: account,
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        created_at: 1.hour.ago
      )
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_created(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
        'communication_thread.updated',
        hash_including(
          id: communication_thread.display_id,
          last_incoming_message_at: incoming_message.created_at.to_i,
          last_outgoing_message_at: message.created_at.to_i
        )
      )
    end

    it 'broadcasts scheduling appointment statuses in communication thread updates' do
      account.enable_features!('communication_threads')
      account.enable_features!('scheduling')
      communication_thread = conversation.refresh_communication_thread!
      create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation, status: 'confirmed')
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_created(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
        'communication_thread.updated',
        hash_including(
          id: communication_thread.display_id,
          scheduling_appointment_statuses: [{ status: 'confirmed', count: 1 }]
        )
      )
    end

    it 'hydrates missing communication thread metadata before dashboard message payloads' do
      account.enable_features!('communication_threads')
      conversation.reload.communication_thread&.destroy!
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_created(event)
      end

      communication_thread = conversation.reload.communication_thread
      dashboard_payload = hash_including(
        account_id: account.id,
        id: message.id,
        communication_thread_id: communication_thread.display_id,
        conversation_id: conversation.display_id,
        inbox_id: inbox.id,
        channel: inbox.channel_type
      )
      customer_payload_without_thread = satisfy do |payload|
        payload[:id] == message.id &&
          payload[:account_id] == account.id &&
          payload[:communication_thread_id].blank?
      end
      thread_payload = hash_including(
        id: communication_thread.display_id,
        communication_thread_id: communication_thread.display_id,
        source_event: 'message.created',
        message: hash_including(
          id: message.id,
          communication_thread_id: communication_thread.display_id,
          conversation_id: conversation.display_id,
          inbox_id: inbox.id,
          channel: inbox.channel_type
        )
      )

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
        'message.created',
        dashboard_payload
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(conversation.contact_inbox.pubsub_token),
        'message.created',
        customer_payload_without_thread
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation)),
        'communication_thread.updated',
        thread_payload
      )
    end

    it 'broadcasts assignee and team in communication thread meta' do
      account.enable_features!('communication_threads')
      communication_thread = conversation.refresh_communication_thread!
      team = create(:team, account: account)
      communication_thread.update!(team: team)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_created(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token, message.sender.pubsub_token),
        'communication_thread.updated',
        hash_including(
          id: communication_thread.display_id,
          meta: hash_including(
            assignee: hash_including(id: agent.id),
            assignee_type: 'User',
            team: hash_including(id: team.id)
          )
        )
      )
    end

    it 'broadcasts explicit nil assignment fields so stale thread assignee and team can be cleared' do
      account.enable_features!('communication_threads')
      communication_thread = conversation.refresh_communication_thread!
      communication_thread.update!(assignee: nil, team: nil)
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_created(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token, message.sender.pubsub_token),
        'communication_thread.updated',
        hash_including(
          id: communication_thread.display_id,
          meta: hash_including(
            assignee: nil,
            assignee_type: nil,
            team: nil
          )
        )
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
      InboxMember.where(user: agent, inbox: second_inbox).delete_all
      InboxMember.where(user: second_agent, inbox: inbox).delete_all
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_created(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        [agent.pubsub_token],
        'communication_thread.updated',
        hash_including(conversation_ids: [conversation.display_id])
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(admin.pubsub_token, message.sender.pubsub_token),
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

  describe '#conversation_read' do
    it 'sends shared unread state only to employees who can view the conversation' do
      team = create(:team, account: account)
      team_member = create(:user, account: account, role: :agent)
      additional_account_agent = create(:user, account: account, role: :agent)
      create(:team_member, team: team, user: team_member)
      InboxMember.where(user: team_member, inbox: inbox).delete_all
      create(:team_member, team: team, user: agent)
      inbox.update!(enable_auto_assignment: false)
      conversation.update!(team: team, agent_last_seen_at: 1.hour.ago)
      create(:user, role: :agent)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 5.minutes.ago)
      Current.user = agent
      event = Events::Base.new(:'conversation.read', Time.current, conversation: conversation)

      expect(inbox.inbox_members.exists?(user: team_member)).to be(false)
      expect(team.team_members.exists?(user: team_member)).to be(true)
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(
          agent.pubsub_token, admin.pubsub_token, team_member.pubsub_token, additional_account_agent.pubsub_token
        ),
        'conversation.read',
        a_hash_including(
          account_id: account.id,
          unread_count: 1,
          performer: a_hash_including(id: agent.id)
        )
      )

      listener.conversation_read(event)
    ensure
      Current.user = nil
    end

    it 'keeps sibling channel details and unread counts scoped to each authorized recipient' do
      account.enable_features!('communication_threads')
      conversation.update!(agent_last_seen_at: 1.hour.ago)
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, created_at: 5.minutes.ago)
      second_conversation, second_agent = create_sibling_thread_context
      communication_thread = conversation.reload.refresh_communication_thread!
      expect(communication_thread.conversation_ids).to contain_exactly(conversation.id, second_conversation.id)
      broadcasts = []
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |members, event_name, payload|
        broadcasts << [members, event_name, payload]
      end
      Current.user = agent
      event = Events::Base.new(:'conversation.read', Time.current, conversation: conversation)

      perform_communication_thread_realtime { listener.conversation_read(event) }

      inbox_agent_payload = broadcasts.find do |members, event_name, _payload|
        members == [agent.pubsub_token] && event_name == 'communication_thread.updated'
      end.last
      admin_payload = broadcasts.find do |members, event_name, _payload|
        members == [admin.pubsub_token] && event_name == 'communication_thread.updated'
      end.last
      expect(inbox_agent_payload).to include(
        conversation_ids: [conversation.display_id],
        unread_count: 1,
        channels: contain_exactly(a_hash_including(conversation_id: conversation.display_id, unread_count: 1))
      )
      expect(inbox_agent_payload.fetch(:conversation_ids)).not_to include(second_conversation.display_id)
      expect(inbox_agent_payload.fetch(:channels).pluck(:conversation_id)).not_to include(second_conversation.display_id)
      expect(admin_payload).to include(
        conversation_ids: contain_exactly(conversation.display_id, second_conversation.display_id),
        unread_count: 2,
        channels: contain_exactly(
          a_hash_including(conversation_id: conversation.display_id, unread_count: 1),
          a_hash_including(conversation_id: second_conversation.display_id, unread_count: 1)
        )
      )
      expect(broadcasts.none? do |members, event_name, _payload|
        members == [second_agent.pubsub_token] && event_name == 'communication_thread.updated'
      end).to be(true)
    ensure
      Current.user = nil
    end
  end

  describe '#message_updated' do
    let(:event_name) { :'message.updated' }
    let!(:message) do
      create(:message, message_type: 'incoming', account: account, inbox: inbox, conversation: conversation, sender: conversation.contact)
    end
    let!(:event) do
      Events::Base.new(event_name, Time.zone.now, message: message, previous_changes: { content: %w[old new] })
    end

    it 'keeps communication thread metadata dashboard-only on message updates' do
      account.enable_features!('communication_threads')
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.message_updated(event)
      end

      communication_thread = conversation.reload.communication_thread
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'message.updated',
        hash_including(
          id: message.id,
          communication_thread_id: communication_thread.display_id,
          previous_changes: { content: %w[old new] }
        )
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(conversation.contact_inbox.pubsub_token),
        'message.updated',
        satisfy do |payload|
          payload[:id] == message.id &&
            payload[:previous_changes] == { content: %w[old new] } &&
            payload[:communication_thread_id].blank? &&
            payload[:inbox_name].blank? &&
            payload[:channel].blank? &&
            payload[:medium].blank? &&
            payload[:contact_inbox_id].blank?
        end
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'communication_thread.updated',
        hash_including(
          source_event: 'message.updated',
          message: hash_including(
            id: message.id,
            communication_thread_id: communication_thread.display_id
          )
        )
      )
    end
  end

  describe '#conversation_created' do
    let(:event_name) { :'conversation.created' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

    it 'broadcasts a communication thread refresh so new linked channels appear without waiting for a message' do
      account.enable_features!('communication_threads')
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.conversation_created(event)
      end

      communication_thread = conversation.reload.communication_thread
      expected_payload = hash_including(
        account_id: account.id,
        id: communication_thread.display_id,
        communication_thread_id: communication_thread.display_id,
        is_communication_thread: true,
        source_event: 'conversation.created',
        conversation_id: conversation.display_id,
        conversation_ids: [conversation.display_id],
        channels: [hash_including(
          conversation_id: conversation.display_id,
          inbox_id: inbox.id,
          channel: inbox.channel_type,
          channel_key: "conversation:#{conversation.display_id}"
        )],
        contact_id: conversation.contact_id,
        meta: hash_including(
          sender: hash_including(id: conversation.contact_id),
          channel: 'CommunicationThread'
        ),
        inbox_id: inbox.id,
        inbox_name: inbox.name,
        channel: inbox.channel_type,
        can_reply: conversation.can_reply?,
        labels: []
      )
      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'communication_thread.updated',
        expected_payload
      )
    end
  end

  describe '#typing_on' do
    let(:event_name) { :'conversation.typing_on' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation, user: agent, is_private: false) }

    it 'accepts the native three-argument keyword payload and keeps the typing recipient policy' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent)
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
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent)
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
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent)
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

    it 'accepts the native three-argument keyword payload and keeps the typing recipient policy' do
      # HACK: to reload conversation inbox members
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent)
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

  describe '#conversation_contact_changed' do
    let(:event_name) { :'conversation.contact_changed' }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, conversation: conversation) }

    it 'broadcasts a communication thread refresh when contact identity/grouping changes' do
      account.enable_features!('communication_threads')
      conversation.refresh_communication_thread!
      new_contact = create(:contact, account: account)
      new_contact_inbox = create(:contact_inbox, contact: new_contact, inbox: inbox)

      conversation.update!(contact: new_contact, contact_inbox: new_contact_inbox)
      communication_thread = conversation.reload.communication_thread
      allow(ActionCableBroadcastJob).to receive(:perform_later)

      perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob) do
        listener.conversation_contact_changed(event)
      end

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(
        a_collection_containing_exactly(agent.pubsub_token, admin.pubsub_token),
        'communication_thread.updated',
        hash_including(
          account_id: account.id,
          id: communication_thread.display_id,
          source_event: 'conversation.contact_changed',
          conversation_id: conversation.display_id,
          contact_id: new_contact.id,
          meta: hash_including(
            sender: hash_including(id: new_contact.id),
            channel: 'CommunicationThread'
          )
        )
      )
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

  describe '#notification_created' do
    let(:event_name) { :'notification.created' }
    let!(:notification) { create(:notification, account: account, user: agent) }
    let!(:event) { Events::Base.new(event_name, Time.zone.now, notification: notification) }

    it 'marks the realtime payload when the inbox notification type is enabled' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.created',
        {
          account_id: notification.account_id,
          notification: notification.push_event_data,
          unread_count: 1,
          count: 1,
          inbox_notification_enabled: true
        }
      )

      listener.notification_created(event)
    end

    it 'marks the realtime payload when the inbox notification type is disabled' do
      setting = agent.notification_settings.find_by!(account_id: account.id)
      setting.update!(selected_inbox_flags: [])

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.created',
        {
          account_id: notification.account_id,
          notification: notification.push_event_data,
          unread_count: 0,
          count: 0,
          inbox_notification_enabled: false
        }
      )

      listener.notification_created(event)
    end
  end

  describe 'notification payloads for a conversation in a communication thread' do
    let!(:communication_thread) do
      account.enable_features!('communication_threads')
      thread = create(:communication_thread, account: account, contact: conversation.contact)
      CommunicationThreadConversation.where(conversation_id: conversation.id).delete_all
      create(:communication_thread_conversation, account: account, communication_thread: thread, conversation: conversation)
      # The link is created behind the already-loaded conversation; drop its
      # cached thread association so it reads the link like a freshly loaded record.
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
      thread
    end
    let!(:notification) do
      create(:notification, account: account, user: agent, notification_type: 'conversation_mention', primary_actor: conversation)
    end

    it 'sends the thread target with notification.created' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.created',
        hash_including(notification: hash_including(communication_thread_id: communication_thread.display_id))
      )

      listener.notification_created(Events::Base.new(:'notification.created', Time.zone.now, notification: notification))
    end

    it 'sends the thread target with notification.updated' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        [agent.pubsub_token],
        'notification.updated',
        hash_including(notification: hash_including(communication_thread_id: communication_thread.display_id))
      )

      listener.notification_updated(Events::Base.new(:'notification.updated', Time.zone.now, notification: notification))
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
      expect(conversation.inbox.reload.members).to contain_exactly(admin, agent)

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation), conversation.contact_inbox.pubsub_token),
        'conversation.updated',
        conversation.push_event_data.merge(account_id: account.id)
      )
      listener.conversation_updated(event)
    end

    it 'broadcast event with label data' do
      expect(conversation.reload.push_event_data[:labels]).to eq(conversation.labels.pluck(:name))

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(*dashboard_tokens(conversation), conversation.contact_inbox.pubsub_token),
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
        Crm::Deals::RealtimeRecipients.new(account: account, deal: deal).tokens,
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

  describe '#crm_task_updated' do
    let(:task) { create(:crm_task, account: account) }
    let(:event) do
      Events::Base.new(
        :'crm.task.updated',
        Time.zone.now,
        account: account,
        task: task,
        meta: { changes: { 'assignee_id' => [nil, agent.id] } }
      )
    end

    it 'sends full task data to authorized private streams and a redacted account invalidation' do
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        a_collection_containing_exactly(admin.pubsub_token, agent.pubsub_token),
        'crm.task.updated',
        hash_including(
          account_id: account.id,
          task_id: task.id,
          task: hash_including(id: task.id),
          meta: { changes: { 'assignee_id' => [nil, agent.id] } }
        )
      ).once
      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        ["account_#{account.id}"],
        'crm.task.updated',
        satisfy do |payload|
          payload == {
            account_id: account.id,
            task_id: task.id,
            meta: { event_type: 'crm.task.updated' }
          }
        end
      ).once

      listener.crm_task_updated(event)
    end
  end

  def create_sibling_thread_context
    second_inbox = create(:inbox, account: account)
    second_conversation = create(
      :conversation,
      account: account,
      contact: conversation.contact,
      inbox: second_inbox,
      contact_inbox: create(:contact_inbox, contact: conversation.contact, inbox: second_inbox),
      agent_last_seen_at: 1.hour.ago
    )
    create(:message, account: account, inbox: second_inbox, conversation: second_conversation,
                     message_type: :incoming, created_at: 5.minutes.ago)
    second_agent = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: second_inbox, user: second_agent)
    InboxMember.where(user: agent, inbox: second_inbox).delete_all
    InboxMember.where(user: second_agent, inbox: inbox).delete_all

    [second_conversation, second_agent]
  end

  def dashboard_tokens(conversation)
    (conversation.inbox.members.pluck(:pubsub_token) + conversation.account.administrators.pluck(:pubsub_token)).uniq
  end

  def perform_communication_thread_realtime(&)
    perform_enqueued_jobs(only: CommunicationThreads::RealtimeUpdateJob, &)
  end
end
