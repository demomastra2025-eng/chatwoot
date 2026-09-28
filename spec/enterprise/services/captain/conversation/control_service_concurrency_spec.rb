require 'rails_helper'
require 'timeout'

RSpec.describe Captain::Conversation::ControlService do
  self.use_transactional_tests = false

  it 'serializes a human reply commit before evaluating a competing stale handoff fence' do
    records = create_race_records
    human_locked = Queue.new
    release_human = Queue.new
    handoff_entered = Queue.new
    handoff_result = Queue.new

    observe_handoff_entry(handoff_entered)
    human_worker = hold_human_reply(records, human_locked, release_human)
    Timeout.timeout(5) { human_locked.pop }
    handoff_worker = run_handoff(records, handoff_result)
    Timeout.timeout(5) { handoff_entered.pop }
    release_human << true
    [human_worker, handoff_worker].each { |worker| Timeout.timeout(5) { worker.join } }

    expect(handoff_result.pop).to eq(:stale)
    expect(records.fetch(:conversation).reload).to have_attributes(
      status: 'open',
      captain_control_generation: 1,
      captain_handoff_applied_at: nil
    )
    expect(records.fetch(:conversation).current_captain_control_state).to eq('human')
  ensure
    release_human << true if defined?(release_human) && release_human.empty?
    human_worker&.join
    handoff_worker&.join
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'does not expose a status change before its status epoch is recorded' do
    records = create_race_records
    conversation_id = records.fetch(:conversation).id
    previous_epoch = ConversationStatusTransition.where(conversation_id: conversation_id).maximum(:id).to_i
    status_saved = Queue.new
    release_transition = Queue.new
    transition_result = Queue.new

    allow_any_instance_of(Conversations::StatusTransitionService).to receive(:record_transition!).and_wrap_original do |method, **kwargs|
      status_saved << true
      release_transition.pop
      method.call(**kwargs)
    end

    transition_worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Conversations::StatusTransitionService.new(
          conversation: Conversation.find(conversation_id), params: { status: 'open' }, source: 'system'
        ).perform
        transition_result << :done
      end
    rescue StandardError => e
      transition_result << e
    end

    Timeout.timeout(5) { status_saved.pop }
    expect(Conversation.find(conversation_id)).to be_pending
    expect(ConversationStatusTransition.where(conversation_id: conversation_id).maximum(:id).to_i).to eq(previous_epoch)

    release_transition << true
    Timeout.timeout(5) { transition_worker.join }
    expect(transition_result.pop).to eq(:done)
    expect(Conversation.find(conversation_id)).to be_open
    expect(ConversationStatusTransition.where(conversation_id: conversation_id).maximum(:id).to_i).to be > previous_epoch
  ensure
    release_transition << true if defined?(release_transition) && release_transition.empty?
    transition_worker&.join
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'publishes takeover cancellation only after the employee reply commits' do
    records = create_race_records
    human_locked = Queue.new
    release_human = Queue.new
    key = cancellation_key(records)
    worker = hold_human_reply(records, human_locked, release_human)
    Timeout.timeout(5) { human_locked.pop }
    expect(Redis::Alfred.get(key)).to be_nil

    release_human << true
    Timeout.timeout(5) { worker.join }
    expect(JSON.parse(Redis::Alfred.get(key))).to include(
      'account_id' => records.fetch(:account).id,
      'conversation_id' => records.fetch(:conversation).id,
      'control_generation' => records.fetch(:expected_generation),
      'last_message_id' => records.fetch(:trigger_message).id,
      'status_transition_id' => 0,
      'cancel_reason' => 'employee_reply'
    )
    # Legacy column is mirrored for the previous release image during rollout.
    expect(records.fetch(:conversation).reload.captain_control_state).to eq('human')
  ensure
    release_human << true if defined?(release_human) && release_human.empty?
    worker&.join
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'does not publish takeover cancellation or change status after a rolled-back employee reply' do
    records = create_race_records
    key = cancellation_key(records)
    Message.transaction do
      create(:message, conversation: records.fetch(:conversation), message_type: :outgoing, sender: records.fetch(:agent))
      expect(Redis::Alfred.get(key)).to be_nil
      raise ActiveRecord::Rollback
    end

    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:conversation).reload).to have_attributes(status: 'pending', captain_control_generation: 0, captain_control_state: 'ai')
    expect(records.fetch(:conversation).messages.outgoing.count).to eq(0)
  ensure
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'captures a pending sibling after a committed reply across channels from an open conversation' do
    records = create_cross_channel_records
    human_locked = Queue.new
    release_human = Queue.new
    key = cancellation_key(records, conversation: records.fetch(:pending_sibling))
    worker = hold_human_reply(records, human_locked, release_human)
    Timeout.timeout(5) { human_locked.pop }
    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(0)

    release_human << true
    Timeout.timeout(5) { worker.join }
    expect(JSON.parse(Redis::Alfred.get(key))).to include(
      'conversation_id' => records.fetch(:pending_sibling).id,
      'control_generation' => 0, 'last_message_id' => records.fetch(:trigger_message).id,
      'status_transition_id' => 0, 'cancel_reason' => 'employee_reply'
    )
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(1)
    expect(records.fetch(:conversation).reload).to be_open
    expect(records.fetch(:pending_sibling).reload).to be_pending
  ensure
    release_human << true if defined?(release_human) && release_human.empty?
    worker&.join
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'preserves a pending sibling after a rolled-back reply across channels from an open conversation' do
    records = create_cross_channel_records
    key = cancellation_key(records, conversation: records.fetch(:pending_sibling))
    Message.transaction do
      create(:message, conversation: records.fetch(:conversation), message_type: :outgoing, sender: records.fetch(:agent))
      expect(Redis::Alfred.get(key)).to be_nil
      raise ActiveRecord::Rollback
    end

    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(0)
    expect(records.fetch(:conversation).reload).to be_open
    expect(records.fetch(:pending_sibling).reload).to be_pending
    expect(records.fetch(:conversation).messages.outgoing.count).to eq(0)
  ensure
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'invalidates a pending sibling in the database when an open source cannot capture cancellation in Redis' do
    records = create_cross_channel_records
    key = cancellation_key(records, conversation: records.fetch(:pending_sibling))
    allow(Captain::Conversation::ResponseCancellationService).to receive(:new).and_wrap_original do |method, **params|
      service = method.call(**params)
      allow(service).to receive(:snapshot).and_raise(Redis::CannotConnectError)
      service
    end

    create(:message, conversation: records.fetch(:conversation), message_type: :outgoing, sender: records.fetch(:agent))

    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(1)
    expect(records.fetch(:conversation).reload).to be_open
    expect(records.fetch(:pending_sibling).reload).to be_pending
    expect(records.fetch(:pending_sibling).bot_handoff!(fence: { control_generation: 0 })).to eq(:stale)
  ensure
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'cancels a pending Captain sibling only after a public non-Captain source reply commits' do
    records = create_non_captain_cross_channel_records
    human_locked = Queue.new
    release_human = Queue.new
    key = cancellation_key(records, conversation: records.fetch(:pending_sibling))
    worker = hold_human_reply(records, human_locked, release_human)
    Timeout.timeout(5) { human_locked.pop }
    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(0)

    release_human << true
    Timeout.timeout(5) { worker.join }
    expect(JSON.parse(Redis::Alfred.get(key))).to include(
      'conversation_id' => records.fetch(:pending_sibling).id,
      'control_generation' => 0, 'last_message_id' => records.fetch(:trigger_message).id,
      'status_transition_id' => 0, 'cancel_reason' => 'employee_reply'
    )
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(1)
    expect(records.fetch(:conversation).reload).to be_open
    expect(records.fetch(:pending_sibling).reload).to be_pending
  ensure
    release_human << true if defined?(release_human) && release_human.empty?
    worker&.join
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'rolls back a non-Captain source takeover without publishing its pending sibling cancellation' do
    records = create_non_captain_cross_channel_records
    key = cancellation_key(records, conversation: records.fetch(:pending_sibling))
    Message.transaction do
      create(:message, conversation: records.fetch(:conversation), message_type: :outgoing, sender: records.fetch(:agent))
      expect(records.fetch(:thread).reload.captain_control_generation).to eq(1)
      expect(Redis::Alfred.get(key)).to be_nil
      raise ActiveRecord::Rollback
    end

    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:thread).reload.captain_control_generation).to eq(0)
    expect(records.fetch(:conversation).reload).to be_open
    expect(records.fetch(:pending_sibling).reload).to be_pending
    expect(records.fetch(:conversation).messages.outgoing.count).to eq(0)
  ensure
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  it 'keeps a database fence when a non-Captain source cannot capture its pending sibling in Redis' do
    records = create_non_captain_cross_channel_records
    key = cancellation_key(records, conversation: records.fetch(:pending_sibling))
    allow(Captain::Conversation::ResponseCancellationService).to receive(:new).and_wrap_original do |method, **params|
      service = method.call(**params)
      allow(service).to receive(:snapshot).and_raise(Redis::CannotConnectError)
      service
    end

    create(:message, conversation: records.fetch(:conversation), message_type: :outgoing, sender: records.fetch(:agent))

    expect(records.fetch(:thread).reload.captain_control_generation).to eq(1)
    expect(records.fetch(:conversation).reload).to be_open
    expect(records.fetch(:pending_sibling).reload).to be_pending
    expect(Redis::Alfred.get(key)).to be_nil
    expect(records.fetch(:pending_sibling).bot_handoff!(fence: { control_generation: 0 })).to eq(:stale)
  ensure
    Redis::Alfred.delete(key) if defined?(key)
    cleanup_race_records(records) if defined?(records) && records
  end

  def cancellation_key(records, conversation: records.fetch(:conversation))
    format(Redis::Alfred::CAPTAIN_RESPONSE_CANCELLATION_STATE, conversation_id: conversation.id)
  end

  def create_non_captain_cross_channel_records
    records = create_cross_channel_records
    source = records.fetch(:conversation)
    CaptainInbox.where(inbox_id: source.inbox_id).destroy_all
    source.inbox.reload
    records
  end

  def create_cross_channel_records
    records = create_race_records
    conversation = records.fetch(:conversation)
    conversation.update!(status: :open)
    thread = create(:communication_thread, account: records.fetch(:account), contact: conversation.contact)
    sibling = create(:conversation, account: records.fetch(:account), contact: conversation.contact, status: :pending)
    create(:captain_inbox, inbox: sibling.inbox, captain_assistant: conversation.inbox.captain_assistant)
    [conversation, sibling].each do |candidate|
      create(:communication_thread_conversation, communication_thread: thread, conversation: candidate)
      candidate.association(:communication_thread_conversation).reset
      candidate.association(:communication_thread).reset
    end
    records.merge(thread: thread, pending_sibling: sibling, expected_generation: thread.captain_control_generation,
                  trigger_message: create(:message, conversation: sibling, message_type: :incoming))
  end

  def create_race_records
    account = create(:account)
    inbox = create(:inbox, account: account)
    assistant = create(:captain_assistant, account: account)
    create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending)
    trigger_message = create(:message, conversation: conversation, message_type: :incoming)

    {
      account: account,
      conversation: conversation,
      trigger_message: trigger_message,
      expected_generation: conversation.captain_control_generation,
      agent: create(:user, account: account)
    }
  end

  def observe_handoff_entry(handoff_entered)
    allow_any_instance_of(described_class).to receive(:apply_handoff).and_wrap_original do |method, *args, **kwargs, &block|
      handoff_entered << true
      method.call(*args, **kwargs, &block)
    end
  end

  def hold_human_reply(records, human_locked, release_human)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Message.transaction do
          create(
            :message,
            conversation: Conversation.find(records.fetch(:conversation).id),
            message_type: :outgoing,
            sender: records.fetch(:agent)
          )
          human_locked << true
          release_human.pop
        end
      end
    end
  end

  def run_handoff(records, result)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        conversation = Conversation.find(records.fetch(:conversation).id)
        result << conversation.bot_handoff!(
          fence: {
            control_generation: records.fetch(:expected_generation),
            last_message_id: records.fetch(:trigger_message).id
          }
        )
      end
    rescue StandardError => e
      result << e
    end
  end

  def cleanup_race_records(records)
    account = records.fetch(:account)
    conversation_ids = [records.fetch(:conversation).id, records[:pending_sibling]&.id].compact
    CommunicationThreadConversation.where(conversation_id: conversation_ids).delete_all
    ConversationStatusTransition.where(conversation_id: conversation_ids).delete_all
    Message.where(conversation_id: conversation_ids).delete_all
    Conversation.where(id: conversation_ids).delete_all
    records[:thread]&.destroy!
    account.destroy!
  end
end
