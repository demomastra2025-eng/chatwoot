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
      captain_control_state: 'human',
      captain_control_generation: 1,
      captain_handoff_applied_at: nil
    )
  ensure
    release_human << true if defined?(release_human) && release_human.empty?
    human_worker&.join
    handoff_worker&.join
    cleanup_race_records(records) if defined?(records) && records
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
    conversation_id = records.fetch(:conversation).id
    ConversationStatusTransition.where(conversation_id: conversation_id).delete_all
    Message.where(conversation_id: conversation_id).delete_all
    Conversation.where(id: conversation_id).delete_all
    account.destroy!
  end
end
