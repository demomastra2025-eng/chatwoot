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

    it 'cancels captured runs across its own thread without opening the sibling or cancelling another account' do
      thread = create(:communication_thread, account: conversation.account, contact: conversation.contact)
      sibling = create(:conversation, account: conversation.account, contact: conversation.contact, status: :pending)
      create(:captain_inbox, inbox: sibling.inbox, captain_assistant: captain_assistant)
      [conversation, sibling].each do |candidate|
        create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
        candidate.association(:communication_thread_conversation).reset
        candidate.association(:communication_thread).reset
      end
      incoming = create(:message, conversation: conversation, message_type: :incoming)
      foreign_conversation = create(:conversation, status: :pending)
      foreign_key = format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: foreign_conversation.id)

      create(:message, message_type: :outgoing, conversation: conversation)

      [conversation, sibling].each do |candidate|
        service = Captain::Conversation::ResponseCancellationService.new(conversation: candidate, assistant: captain_assistant)
        expect(service.cancelled?(expected_last_message_id: incoming.id, expected_control_generation: 0, expected_status_transition_id: 0)).to be true
        expect(service.cancelled?(expected_last_message_id: incoming.id, expected_control_generation: 1, expected_status_transition_id: 0))
          .to be false
      end
      expect(sibling.reload).to be_pending
      expect(thread.reload.captain_control_state).to eq('human')
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
end
