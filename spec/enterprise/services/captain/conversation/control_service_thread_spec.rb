require 'rails_helper'

RSpec.describe Captain::Conversation::ControlService do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:thread) { create(:communication_thread, account: account, contact: contact) }
  let(:first_conversation) { create(:conversation, account: account, contact: contact, status: :pending) }
  let(:second_conversation) { create(:conversation, account: account, contact: contact, status: :pending) }

  before do
    create(:communication_thread_conversation, communication_thread: thread, conversation: first_conversation)
    create(:communication_thread_conversation, communication_thread: thread, conversation: second_conversation)
    [first_conversation, second_conversation].each do |conversation|
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
    end
  end

  it 'moves every linked conversation to human control with one thread generation' do
    stale_generation = second_conversation.current_captain_control_generation

    first_conversation.activate_captain_human_control!(source: 'agent_reply')

    expect(thread.reload).to have_attributes(
      captain_control_state: 'human',
      captain_control_generation: stale_generation + 1
    )
    expect(second_conversation.reload).to be_captain_human_control_active
    expect(second_conversation.bot_handoff!(fence: { control_generation: stale_generation })).to eq(:stale)
  end

  it 'returns the thread to AI control once and invalidates older generations' do
    first_conversation.activate_captain_human_control!(source: 'agent_reply')
    human_generation = thread.reload.captain_control_generation

    expect(second_conversation.prepare_captain_ai_control!).to be(true)
    expect(first_conversation.reload).not_to be_captain_human_control_active
    expect(thread.reload).to have_attributes(
      captain_control_state: 'ai',
      captain_control_generation: human_generation + 1,
      captain_handoff_applied_at: nil
    )
  end

  it 'locks the thread owner before the conversation during explicit release' do
    agent = create(:user, account: account)
    first_conversation.activate_captain_human_control!(source: 'agent_reply')
    expect(second_conversation).to receive(:with_captain_control_lock).ordered.and_call_original
    expect(second_conversation).to receive(:with_lock).ordered.and_call_original

    Conversations::StatusTransitionService.new(
      conversation: second_conversation,
      params: { status: 'pending' },
      actor: agent,
      source: 'api'
    ).perform

    expect(thread.reload.captain_control_state).to eq('ai')
  end

  it 'reloads stale status after locking the conversation row' do
    agent = create(:user, account: account)
    stale_conversation = second_conversation
    # Simulate an external committed update without refreshing the loaded instance.
    # rubocop:disable Rails/SkipsModelValidations
    Conversation.where(id: stale_conversation.id).update_all(status: Conversation.statuses[:resolved])
    # rubocop:enable Rails/SkipsModelValidations

    Conversations::StatusTransitionService.new(
      conversation: stale_conversation,
      params: { status: 'pending' },
      actor: agent,
      source: 'api'
    ).perform

    expect(stale_conversation.reload.status).to eq('pending')
    expect(stale_conversation.status_transitions.order(:id).last).to have_attributes(
      from_status: 'resolved', to_status: 'pending'
    )
  end

  it 'does not hold the conversation row while waiting for the thread owner lock' do
    agent = create(:user, account: account)
    first_conversation.activate_captain_human_control!(source: 'agent_reply')
    owner_locked = Queue.new
    release_owner = Queue.new
    release_attempted = Queue.new
    errors = Queue.new

    owner_holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        locked_conversation = Conversation.find(second_conversation.id)
        locked_conversation.with_captain_control_lock do
          owner_locked << true
          release_owner.pop
          locked_conversation.with_lock { locked_conversation.reload }
        end
      rescue StandardError => e
        errors << e
      end
    end
    Timeout.timeout(2) { owner_locked.pop }

    release = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        stale_conversation = Conversation.find(second_conversation.id)
        stale_conversation.define_singleton_method(:with_captain_control_lock) do |&block|
          release_attempted << true
          super(&block)
        end
        Conversations::StatusTransitionService.new(
          conversation: stale_conversation,
          params: { status: 'pending' },
          actor: agent,
          source: 'api'
        ).perform
      rescue StandardError => e
        errors << e
      end
    end
    Timeout.timeout(2) { release_attempted.pop }

    Conversation.transaction do
      expect(Conversation.lock('FOR UPDATE NOWAIT').find(second_conversation.id)).to be_present
    end

    release_owner << true
    [owner_holder, release].each { |worker| Timeout.timeout(5) { worker.join } }
    raise errors.pop unless errors.empty?
  ensure
    release_owner << true if defined?(release_owner) && release_owner.empty?
    [owner_holder, release].compact.each { |worker| worker.join(1) }
  end
end
