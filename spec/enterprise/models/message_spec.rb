require 'rails_helper'

RSpec.describe Message do
  let!(:conversation) { create(:conversation) }

  it 'updates first reply if the message is human and even if there are messages from captain' do
    captain_assistant = create(:captain_assistant, account: conversation.account)
    expect(conversation.first_reply_created_at).to be_nil

    ## There is a difference on how the time is stored in the database and how it is retrieved
    # This is because of the precision of the time stored in the database
    # In the test, we will check whether the time is within the range
    expect(conversation.waiting_since).to be_within(0.000001.seconds).of(conversation.created_at)

    create(:message, message_type: :outgoing, conversation: conversation, sender: captain_assistant)

    # Captain::Assistant responses clear waiting_since (like AgentBot)
    expect(conversation.first_reply_created_at).to be_nil
    expect(conversation.waiting_since).to be_nil

    create(:message, message_type: :outgoing, conversation: conversation)

    expect(conversation.first_reply_created_at).not_to be_nil
    expect(conversation.waiting_since).to be_nil
  end

  describe '#mark_pending_conversation_as_open_for_human_response' do
    let(:conversation) { create(:conversation, status: :pending) }
    let(:captain_assistant) { create(:captain_assistant, account: conversation.account) }
    let(:auto_open_activity_content) { I18n.t('conversations.activity.captain.auto_opened_after_agent_reply') }

    before do
      create(:captain_inbox, inbox: conversation.inbox, captain_assistant: captain_assistant)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    it 'marks the conversation open when a human sends a public outgoing message' do
      create(:message, message_type: :outgoing, conversation: conversation)

      expect(conversation.reload.open?).to be true
      expect(conversation).to be_captain_human_control_active
      expect(conversation.captain_control_generation).to eq(1)
      # Write-only bridge for the previous release image during rollout/rollback.
      expect(conversation.captain_control_state).to eq('human')
    end

    it 'keeps the conversation open without incrementing the generation for later replies' do
      create(:message, message_type: :outgoing, conversation: conversation)
      create(:message, message_type: :outgoing, conversation: conversation)

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(1)
    end

    it 'keeps an already open conversation out of AI control' do
      conversation.update!(status: :open)

      create(:message, message_type: :outgoing, conversation: conversation)

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(0)
    end

    it 'keeps the employee reply and open status when the cancellation snapshot cannot reach Redis' do
      allow(Captain::Conversation::ResponseCancellationService).to receive(:new).and_wrap_original do |method, **params|
        service = method.call(**params)
        allow(service).to receive(:snapshot).and_raise(Redis::CannotConnectError)
        service
      end

      expect { create(:message, message_type: :outgoing, conversation: conversation) }.not_to raise_error
      expect(conversation.reload).to have_attributes(status: 'open', captain_control_generation: 1, captain_control_state: 'human')
    end

    it 'keeps the employee reply and open status when post-commit cancellation cannot reach Redis' do
      allow(Captain::Conversation::ResponseCancellationService).to receive(:new).and_wrap_original do |method, **params|
        service = method.call(**params)
        allow(service).to receive(:perform).and_raise(Redis::CannotConnectError)
        service
      end

      expect { create(:message, message_type: :outgoing, conversation: conversation) }.not_to raise_error
      expect(conversation.reload).to have_attributes(status: 'open', captain_control_generation: 1, captain_control_state: 'human')
    end

    it 'cancels each conversation run on thread takeover without opening the sibling or cancelling another account' do
      thread = create(:communication_thread, account: conversation.account, contact: conversation.contact)
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: captain_assistant)
      [conversation, sibling].each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      incoming = create(:message, conversation: conversation, message_type: :incoming)
      sibling_incoming = create(:message, conversation: sibling, message_type: :incoming)
      foreign_conversation = create(:conversation, status: :pending)
      foreign_key = format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: foreign_conversation.id)

      create(:message, message_type: :outgoing, conversation: conversation)

      [[conversation, incoming], [sibling, sibling_incoming]].each do |candidate, candidate_incoming|
        service = Captain::Conversation::ResponseCancellationService.new(conversation: candidate, assistant: captain_assistant)
        expect(service.cancelled?(expected_last_message_id: candidate_incoming.id, expected_control_generation: 0,
                                  expected_status_transition_id: 0)).to be true
        other_incoming = candidate == conversation ? sibling_incoming : incoming
        expect(service.cancelled?(expected_last_message_id: other_incoming.id, expected_control_generation: 0,
                                  expected_status_transition_id: 0)).to be false
        expect(service.cancelled?(expected_last_message_id: candidate_incoming.id, expected_control_generation: 1,
                                  expected_status_transition_id: 0))
          .to be false
      end
      expect(sibling.reload).to be_pending
      expect(thread.reload).to have_attributes(captain_control_state: 'human', captain_control_generation: 1)
      expect(Redis::Alfred.get(foreign_key)).to be_nil
    ensure
      [conversation, sibling].compact.each do |candidate|
        Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: candidate.id))
      end
    end

    it 'creates an activity message when a human sends a public outgoing message' do
      expect do
        create(:message, message_type: :outgoing, conversation: conversation)
      end.to have_enqueued_job(Conversations::ActivityMessageJob).with(
        conversation,
        {
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id,
          message_type: :activity,
          content: auto_open_activity_content
        }
      )
    end

    it 'creates the activity message in the current request locale' do
      conversation.account.update!(locale: 'en')

      I18n.with_locale(:ru) do
        expect do
          create(:message, message_type: :outgoing, conversation: conversation)
        end.to have_enqueued_job(Conversations::ActivityMessageJob).with(
          conversation,
          hash_including(
            content: I18n.t('conversations.activity.captain.auto_opened_after_agent_reply')
          )
        )
      end
    end

    it 'turns off the captain typing indicator when a human takes over' do
      create(:message, message_type: :outgoing, conversation: conversation)

      expect(Captain::Conversation::TypingIndicatorService).to have_received(:turn_off).with(
        conversation: conversation,
        assistant: captain_assistant
      )
    end

    it 'creates an activity message for external echo replies' do
      message = build(
        :message,
        message_type: :outgoing,
        conversation: conversation,
        content_attributes: { external_echo: true }
      )
      message.sender = nil

      expect do
        message.save!
      end.to have_enqueued_job(Conversations::ActivityMessageJob).with(
        conversation,
        {
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id,
          message_type: :activity,
          content: auto_open_activity_content
        }
      )
    end

    it 'does not mark the conversation open for private outgoing messages' do
      create(:message, message_type: :outgoing, conversation: conversation, private: true)

      expect(conversation.reload.pending?).to be true
    end

    it 'does not mark the conversation open for bot outgoing messages' do
      agent_bot = create(:agent_bot, account: conversation.account)
      create(:message, message_type: :outgoing, conversation: conversation, sender: agent_bot)

      expect(conversation.reload.pending?).to be true
    end

    it 'does not mark the conversation open for scheduled touch messages sent by a user' do
      expect do
        create(
          :message,
          message_type: :outgoing,
          conversation: conversation,
          sender: create(:user, account: conversation.account),
          content_attributes: { touch_id: 123, touch_source: 'touch' }
        )
      end.not_to have_enqueued_job(Conversations::ActivityMessageJob)

      expect(conversation.reload.pending?).to be true
    end
  end

  describe '#activate_captain_human_control_for_human_response' do
    let(:captain_assistant) { create(:captain_assistant, account: conversation.account) }

    before { allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off) }

    def conversation_lock_queries(&)
      queries = []
      collect = lambda do |*, payload|
        sql = payload[:sql].to_s
        queries << sql if sql.include?('FOR UPDATE') && sql.include?('"conversations"')
      end
      ActiveSupport::Notifications.subscribed(collect, 'sql.active_record', &)
      queries
    end

    def link_thread(*conversations)
      thread = create(:communication_thread, account: conversation.account, contact: conversation.contact)
      conversations.each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      thread
    end

    it 'neither locks nor reloads a thread-less conversation outside Captain inboxes' do
      inbox = conversation.inbox
      channel = inbox.channel
      allow(conversation).to receive(:reload).and_call_original

      queries = conversation_lock_queries { create(:message, message_type: :outgoing, conversation: conversation) }

      expect(queries).to be_empty
      expect(conversation).not_to have_received(:reload)
      expect(conversation.inbox).to be(inbox)
      expect(conversation.inbox.channel).to be(channel)
      expect(Conversation.find(conversation.id).captain_control_generation).to eq(0)
    end

    it 'locks a Captain conversation without swapping its cached inbox and channel' do
      create(:captain_inbox, inbox: conversation.inbox, captain_assistant: captain_assistant)
      inbox = conversation.inbox
      channel = inbox.channel
      allow(conversation).to receive(:reload).and_call_original

      queries = conversation_lock_queries { create(:message, message_type: :outgoing, conversation: conversation) }

      expect(queries).not_to be_empty
      expect(conversation).not_to have_received(:reload)
      expect(conversation.inbox).to be(inbox)
      expect(conversation.inbox.channel).to be(channel)
    end

    it 'takes over a pending Captain sibling from a non-Captain channel without swapping cached associations' do
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: captain_assistant)
      thread = link_thread(conversation, sibling)
      cached_thread = conversation.communication_thread
      inbox = conversation.inbox
      allow(conversation).to receive(:reload).and_call_original

      create(:message, message_type: :outgoing, conversation: conversation)

      expect(conversation).not_to have_received(:reload)
      expect(conversation.inbox).to be(inbox)
      expect(conversation.communication_thread).to be(cached_thread)
      expect(cached_thread.captain_control_generation).to eq(1)
      expect(thread.reload.captain_control_generation).to eq(1)
      expect(sibling.reload).to be_pending
    ensure
      Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: sibling.id)) if sibling
    end
  end

  describe 'orphan pending handoff on customer and employee activity' do
    let(:conversation) { create(:conversation, status: :pending) }
    let(:employee) { create(:user, account: conversation.account) }

    before do
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_on)
      allow(Captain::Conversation::TypingIndicatorService).to receive(:turn_off)
    end

    def persist_without_delivery(message)
      message.skip_send_reply = true
      message.save!
    end

    def customer_message(conversation, **attributes)
      build(
        :message,
        {
          account: conversation.account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: conversation.contact,
          message_type: :incoming
        }.merge(attributes)
      )
    end

    def employee_message(conversation, **attributes)
      message = build(
        :message,
        {
          account: conversation.account,
          inbox: conversation.inbox,
          conversation: conversation,
          sender: employee,
          message_type: :outgoing,
          private: false
        }.merge(attributes)
      )
      message.sender = nil if attributes.key?(:sender) && attributes[:sender].nil?
      message
    end

    def link_thread(*conversations)
      first = conversations.first
      thread = create(:communication_thread, account: first.account, contact: first.contact)

      conversations.each do |candidate|
        link = CommunicationThreadConversation.find_by(conversation_id: candidate.id)
        if link
          link.update!(communication_thread: thread)
        else
          create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        end
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      thread
    end

    def expect_orphan_open_notifications(dispatcher)
      payload = hash_including(conversation: conversation)
      expect(dispatcher).to have_received(:dispatch).with(
        Events::Types::CONVERSATION_OPENED, anything, payload
      )
      expect(dispatcher).to have_received(:dispatch).with(
        Events::Types::CONVERSATION_STATUS_CHANGED, anything, payload
      )
    end

    it 'opens an orphan after a new customer message and keeps assignment and history' do
      previous_message = customer_message(conversation)
      previous_message.skip_runtime_events = true
      persist_without_delivery(previous_message)
      team = create(:team, account: conversation.account)
      conversation.inbox.add_members([employee.id])
      team.add_members([employee.id])
      conversation.update!(assignee: employee, team: team)
      dispatcher = Rails.configuration.dispatcher
      allow(dispatcher).to receive(:dispatch).and_call_original

      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
      expect { persist_without_delivery(customer_message(conversation)) }
        .to change { conversation.reload.status }.from('pending').to('open')

      expect_orphan_open_notifications(dispatcher)
      expect(conversation.reload).to have_attributes(
        captain_control_generation: 1,
        captain_control_state: 'human',
        captain_handoff_applied_at: nil,
        assignee_id: employee.id,
        team_id: team.id
      )
      expect(conversation.messages.pluck(:id)).to include(previous_message.id)
      expect(conversation.status_transitions.last).to have_attributes(
        from_status: 'pending', to_status: 'open', source: 'system', actor_id: nil
      )
    end

    it 'opens an orphan after a public human reply' do
      dispatcher = Rails.configuration.dispatcher
      allow(dispatcher).to receive(:dispatch).and_call_original

      expect { persist_without_delivery(employee_message(conversation)) }
        .to change { conversation.reload.status }.from('pending').to('open')

      expect_orphan_open_notifications(dispatcher)
      expect(conversation.reload).to have_attributes(
        captain_control_generation: 1,
        captain_control_state: 'human',
        captain_handoff_applied_at: nil
      )
      expect(conversation.status_transitions.last).to have_attributes(
        from_status: 'pending', to_status: 'open', source: 'system', actor_id: nil
      )
    end

    it 'increments the control generation only once across later public replies' do
      persist_without_delivery(employee_message(conversation))
      persist_without_delivery(employee_message(conversation))

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(1)
      expect(conversation.status_transitions.count).to eq(1)
    end

    it 'continues to treat a public external echo as a human reply' do
      message = employee_message(conversation, sender: nil, content_attributes: { external_echo: true })
      message.skip_runtime_events = true

      persist_without_delivery(message)

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(1)
    end

    it 'recognizes imported history metadata stored as a JSON string' do
      message = customer_message(conversation)
      allow(message).to receive(:content_attributes).and_return('{"imported_history":true}')

      expect(message.send(:imported_history_message?)).to be true
    end

    it 'does not treat an imported external echo as a new human reply' do
      message = employee_message(
        conversation,
        sender: nil,
        content_attributes: { external_echo: true, imported_history: true }
      )
      message.skip_runtime_events = true

      persist_without_delivery(message)

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
    end

    it 'keeps an active linked Captain conversation pending and schedules its response' do
      assistant = create(:captain_assistant, account: conversation.account)
      create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
      conversation.inbox.reload

      expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(
        conversation,
        assistant,
        hash_including(expected_last_message_id: kind_of(Integer))
      )

      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.status_transitions).to be_empty
    end

    it 'keeps a runtime-suppressed public reply from opening a linked Captain conversation' do
      assistant = create(:captain_assistant, account: conversation.account)
      create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
      conversation.inbox.reload
      message = employee_message(conversation)
      message.skip_runtime_events = true

      persist_without_delivery(message)

      expect(conversation.reload).to be_pending
    end

    it 'preserves the linked Captain schedule-off path for staff' do
      assistant = create(:captain_assistant, account: conversation.account)
      captain_inbox = create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
      conversation.inbox.update!(working_hours_enabled: true)
      current_hours = conversation.inbox.working_hours.find_by(
        day_of_week: Time.current.in_time_zone(conversation.inbox.timezone).wday
      )
      current_hours.update!(open_all_day: true, closed_all_day: false)
      captain_inbox.update!(auto_reply_mode: 'outside_working_hours')
      conversation.inbox.reload

      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:perform_later)
      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.captain_handoff_applied_at).to be_nil
      expect(conversation.status_transitions.last).to have_attributes(source: 'system', actor_id: nil)
    end

    it 'keeps pending conversations owned by an active inbox AgentBot' do
      agent_bot = create(:agent_bot, account: conversation.account)
      create(:agent_bot_inbox, inbox: conversation.inbox, agent_bot: agent_bot, status: 'active')

      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.status_transitions).to be_empty
    end

    it 'keeps pending conversations assigned to an AgentBot' do
      conversation.update!(assignee_agent_bot: create(:agent_bot, account: conversation.account))

      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
    end

    it 'opens when an AgentBot inbox link exists but is inactive and no bot is assigned' do
      agent_bot = create(:agent_bot, account: conversation.account)
      create(:agent_bot_inbox, inbox: conversation.inbox, agent_bot: agent_bot, status: 'inactive')

      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(1)
    end

    it 'rechecks an inbox bot that was deactivated after its association was cached' do
      agent_bot = create(:agent_bot, account: conversation.account)
      link = create(:agent_bot_inbox, inbox: conversation.inbox, agent_bot: agent_bot, status: 'active')
      expect(conversation.inbox.agent_bot_inbox).to eq(link)

      AgentBotInbox.find(link.id).update!(status: 'inactive')
      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(1)
    end

    it 'rechecks a Captain link that was removed after its association was cached' do
      assistant = create(:captain_assistant, account: conversation.account)
      inbox = conversation.inbox
      link = create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
      inbox.reload
      expect(inbox.captain_assistant).to eq(assistant)

      CaptainInbox.find(link.id).destroy!
      expect(inbox.captain_assistant).to eq(assistant)
      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_open
      expect(conversation.captain_control_generation).to eq(1)
    end

    it 'keeps pending when an inbox bot activates between candidate detection and the control lock' do
      agent_bot = create(:agent_bot, account: conversation.account)
      link = create(:agent_bot_inbox, inbox: conversation.inbox, agent_bot: agent_bot, status: 'inactive')
      conversation.inbox.agent_bot_inbox
      activated = false

      allow(conversation).to receive(:ai_pending_handler_present?).and_wrap_original do |original, fresh_inbox: false|
        handler_present = original.call(fresh_inbox: fresh_inbox)
        if fresh_inbox && !handler_present && !activated
          AgentBotInbox.find(link.id).update!(status: 'active')
          activated = true
        end
        handler_present
      end

      persist_without_delivery(customer_message(conversation))

      expect(activated).to be true
      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.status_transitions).to be_empty
    end

    it 'does not open for private, automated, campaign, touch, bot, system, or non-message replies' do
      agent_bot = create(:agent_bot, account: conversation.account)
      messages = [
        [:private, employee_message(conversation, private: true)],
        [:automation, employee_message(conversation, content_attributes: { automation_rule_id: 1 })],
        [:campaign, employee_message(conversation, additional_attributes: { campaign_id: 1 })],
        [:scheduled_touch, employee_message(conversation, content_attributes: { touch_id: 1 })],
        [:agent_bot, employee_message(conversation, sender: agent_bot)],
        [:system_sender, employee_message(conversation, sender: nil)],
        [:activity, employee_message(conversation, message_type: :activity)]
      ]

      messages.each do |description, message|
        persist_without_delivery(message)
        expect(conversation.reload).to be_pending, "opened after #{description} reply"
      end

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.status_transitions).to be_empty
    end

    it 'does not open for private, voice-call, transcript, or imported-history customer messages' do
      messages = [
        customer_message(conversation, private: true),
        customer_message(conversation, content_type: :voice_call),
        customer_message(conversation, content_attributes: { 'data' => { 'type' => 'ai_voice_transcript_turn' } }),
        customer_message(conversation, content_attributes: { imported_history: true })
      ]

      messages.each do |message|
        persist_without_delivery(message)
        expect(conversation.reload).to be_pending
      end

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.status_transitions).to be_empty
    end

    it 'does not open when runtime events are suppressed' do
      message = customer_message(conversation)
      message.skip_runtime_events = true

      persist_without_delivery(message)

      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
      expect(conversation.status_transitions).to be_empty
    end

    it 'does not open API-channel or non-Contact incoming messages' do
      api_channel = create(:channel_api, account: conversation.account)
      api_conversation = create(
        :conversation,
        account: conversation.account,
        inbox: api_channel.inbox,
        contact: conversation.contact,
        status: :pending
      )
      persist_without_delivery(customer_message(api_conversation))
      non_contact = customer_message(conversation, sender: create(:agent_bot, account: conversation.account))
      persist_without_delivery(non_contact)

      expect(api_conversation.reload).to be_pending
      expect(conversation.reload).to be_pending
      expect(conversation.captain_control_generation).to eq(0)
    end

    it 'keeps normal resolved and snoozed incoming-message reopening unchanged' do
      resolved = create(:conversation, account: conversation.account, status: :resolved)
      snoozed = create(:conversation, account: conversation.account, status: :snoozed)

      persist_without_delivery(customer_message(resolved))
      persist_without_delivery(customer_message(snoozed))

      expect(resolved.reload).to be_open
      expect(snoozed.reload).to be_open
      expect(resolved.captain_control_generation).to eq(0)
      expect(snoozed.captain_control_generation).to eq(0)
    end

    it 'opens only the current pending conversation when a communication thread is shared' do
      conversation.account.enable_features!('communication_threads')
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      thread = link_thread(conversation, sibling)

      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_open
      expect(sibling.reload).to be_pending
      expect(thread.reload.captain_control_generation).to eq(1)
      expect(conversation.captain_control_generation).to eq(0)
    end

    it 'opens an orphan inbox on incoming activity while fencing an active Captain sibling run' do
      conversation.account.enable_features!('communication_threads')
      assistant = create(:captain_assistant, account: conversation.account)
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: assistant)
      sibling.inbox.reload
      thread = link_thread(conversation, sibling)

      previous_incoming = customer_message(sibling)
      previous_incoming.skip_runtime_events = true
      persist_without_delivery(previous_incoming)
      state = {
        account_id: sibling.account_id,
        assistant_id: assistant.id,
        conversation: { id: sibling.id },
        captain_response_fence: {
          last_message_id: previous_incoming.id,
          status_transition_id: 0,
          control_generation: 0
        }
      }

      persist_without_delivery(customer_message(conversation))

      expect(conversation.reload).to be_open
      expect(sibling.reload).to be_pending
      expect(sibling.inbox.reload.captain_assistant).to eq(assistant)
      expect(thread.reload.captain_control_generation).to eq(1)
      expect do
        Captain::Conversation::RunFenceService.new(assistant: assistant, state: state).ensure_current!
      end.to raise_error(Captain::Conversation::ControlGenerationStaleError, /control_generation_changed/)
    end

    it 'uses the current communication-thread owner when its cached association is stale' do
      conversation.account.enable_features!('communication_threads')
      previous_thread = link_thread(conversation)
      current_thread = create(
        :communication_thread, account: conversation.account, contact: conversation.contact
      )
      thread_link = CommunicationThreadConversation.find_by!(conversation_id: conversation.id)
      message = customer_message(conversation)

      allow(message).to receive(:activate_orphan_pending_human_control_after_commit).and_wrap_original do |handoff|
        cached_thread = conversation.communication_thread
        expect(cached_thread).to eq(previous_thread)
        thread_link.update!(communication_thread: current_thread)
        expect(conversation.communication_thread).to be(cached_thread)
        handoff.call
      end

      persist_without_delivery(message)

      expect(conversation.reload).to be_open
      expect(previous_thread.reload.captain_control_generation).to eq(0)
      expect(current_thread.reload).to have_attributes(
        captain_control_generation: 1,
        captain_control_state: 'human'
      )
    end

    it 'rechecks an interphase control-generation change before reusing a linked takeover' do
      conversation.account.enable_features!('communication_threads')
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :open)
      thread = link_thread(conversation, sibling)
      assistant = create(:captain_assistant, account: conversation.account)
      captain_inbox = create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
      message = employee_message(conversation)

      allow(message).to receive(:orphan_pending_handoff_trigger?).and_wrap_original do |predicate|
        captain_inbox.destroy! if captain_inbox.persisted?
        predicate.call
      end
      allow(message).to receive(:activate_orphan_pending_human_control_after_commit).and_wrap_original do |handoff|
        sibling.prepare_captain_ai_control!
        handoff.call
      end

      persist_without_delivery(message)

      expect(conversation.reload).to be_open
      expect(sibling.reload).to be_open
      expect(thread.reload).to have_attributes(
        captain_control_generation: 3,
        captain_control_state: 'human'
      )
      expect(conversation.status_transitions.count).to eq(1)
    end

    it 'clears linked takeover state when the same message is retried after rollback' do
      assistant = create(:captain_assistant, account: conversation.account)
      create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
      message = employee_message(conversation)
      message.skip_send_reply = true
      captured_services = []

      Message.transaction do
        message.save!
        captured_services = message.instance_variable_get(:@captain_takeover_cancellations).map(&:first)
        expect(captured_services).not_to be_empty
        raise ActiveRecord::Rollback
      end

      expect(message).to be_new_record
      expect(conversation.reload).to have_attributes(status: 'pending', captain_control_generation: 0)
      captured_services.each { |service| expect(service).not_to receive(:perform) }

      message.private = true
      persist_without_delivery(message)

      expect(conversation.reload).to have_attributes(status: 'pending', captain_control_generation: 0)
      expect(message.instance_variable_get(:@captain_takeover_cancellations)).to be_nil
    end

    it 'does not open an API orphan on a public reply when its thread has a linked Captain sibling' do
      conversation.account.enable_features!('communication_threads')
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      assistant = create(:captain_assistant, account: conversation.account)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: assistant)
      api_inbox = create(:channel_api, account: conversation.account).inbox
      api_conversation = create(
        :conversation,
        account: conversation.account,
        inbox: api_inbox,
        contact: conversation.contact,
        status: :pending
      )
      link_thread(api_conversation, sibling)

      persist_without_delivery(employee_message(api_conversation))

      expect(api_conversation.reload).to be_pending
      expect(sibling.reload).to be_pending
    ensure
      [api_conversation, sibling].compact.each do |candidate|
        Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: candidate.id))
      end
    end

    it 'does not open an orphan for an imported public external echo when its thread has a linked Captain sibling' do
      conversation.account.enable_features!('communication_threads')
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      assistant = create(:captain_assistant, account: conversation.account)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: assistant)
      link_thread(conversation, sibling)
      message = employee_message(
        conversation,
        sender: nil,
        content_attributes: { external_echo: true, imported_history: true }
      )
      message.skip_runtime_events = true

      persist_without_delivery(message)

      expect(conversation.reload).to be_pending
      expect(sibling.reload).to be_pending
    ensure
      [conversation, sibling].compact.each do |candidate|
        Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: candidate.id))
      end
    end

    it 'opens an orphan staff-reply target without changing its linked Captain sibling' do
      conversation.account.enable_features!('communication_threads')
      assistant = create(:captain_assistant, account: conversation.account)
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: assistant)
      incoming = customer_message(sibling)
      incoming.skip_runtime_events = true
      persist_without_delivery(incoming)
      thread = link_thread(conversation, sibling)

      persist_without_delivery(employee_message(conversation))

      cancellation = Captain::Conversation::ResponseCancellationService.new(
        conversation: sibling,
        assistant: assistant,
        actor: employee
      )
      expect(conversation.reload).to be_open
      expect(sibling.reload).to be_pending
      expect(thread.reload.captain_control_generation).to eq(1)
      expect(
        cancellation.cancelled?(
          expected_last_message_id: incoming.id,
          expected_control_generation: 0,
          expected_status_transition_id: 0
        )
      ).to be true
    ensure
      [conversation, sibling].compact.each do |candidate|
        Redis::Alfred.delete(format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: candidate.id))
      end
    end
  end
end
