# frozen_string_literal: true

require 'rails_helper'
require 'timeout'

RSpec.describe Reminders::ExecuteService do
  self.use_transactional_tests = false

  after { CommittedRowsCleanup.truncate! }

  def in_thread(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end

  def wait_for_signal(queue, worker, timeout: 10)
    Timeout.timeout(timeout) do
      loop do
        begin
          return queue.pop(true)
        rescue ThreadError
          unless worker.alive?
            result = worker.value
            raise "Worker exited before signaling: #{result.inspect}"
          end
          sleep 0.01
        end
      end
    end
  end

  it 'serializes a real employee reply against follow-up materialization without a lock inversion' do
    account = create(:account)
    account.enable_features!('captain_integration')
    account.enable_features!('captain_tasks')
    inbox = create(:inbox, account: account)
    conversation = create(:conversation, account: account, inbox: inbox, status: :pending)
    assistant = create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => '',
          'steps' => [{ 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 }]
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming)
    anchor = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      sender: assistant,
      message_type: :outgoing,
      private: false,
      additional_attributes: { captain_ai_reply: { assistant_id: assistant.id } }
    )
    reminder = Captain::Conversation::FollowUpJob.schedule!(
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor,
      step: { index: 0, delay_seconds: 60 },
      control_fence: {
        control_generation: conversation.current_captain_control_generation,
        status_transition_id: conversation.status_transitions.maximum(:id).to_i,
        last_message_id: incoming.id
      }
    )
    reminder.update!(scheduled_at: 1.minute.ago)
    claim = reminder.mark_processing!
    employee = create(:user, account: account)
    cancellation_entered = Queue.new
    release_cancellation = Queue.new
    execution_lock_entered = Queue.new
    release_execution_lock = Queue.new

    allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_wrap_original do |original, **attributes|
      evaluator = original.call(**attributes)
      allow(evaluator).to receive(:make_api_call).and_return(
        error: nil,
        message: { 'complete' => false, 'reason' => 'The customer has not replied' }
      )
      evaluator
    end
    allow(Captain::Conversation::FollowUpChainService).to receive(:cancel_for!).and_wrap_original do |original, *args, **kwargs|
      if Thread.current[:pause_follow_up_cancellation]
        cancellation_entered << true
        Timeout.timeout(10) { release_cancellation.pop }
      end
      original.call(*args, **kwargs)
    end
    allow_any_instance_of(Reminders::ExecutionLockService).to receive(:perform).and_wrap_original do |original, *args, **kwargs, &block|
      if Thread.current[:announce_follow_up_lock]
        execution_lock_entered << true
        Timeout.timeout(10) { release_execution_lock.pop }
      end
      original.call(*args, **kwargs, &block)
    end

    executor_thread = in_thread do
      Thread.current[:announce_follow_up_lock] = true
      Reminders::ExecuteService.new(reminder: Reminder.find(reminder.id), processing_claim: claim).perform
    end
    wait_for_signal(execution_lock_entered, executor_thread)

    employee_thread = in_thread do
      Thread.current[:pause_follow_up_cancellation] = true
      Message.create!(
        account: account,
        inbox: inbox,
        conversation: conversation,
        sender: employee,
        message_type: :outgoing,
        private: false,
        content: 'A staff member is taking over.'
      )
    end
    wait_for_signal(cancellation_entered, employee_thread)

    release_execution_lock << true
    sleep 0.1
    release_cancellation << true

    results = [employee_thread, executor_thread].map { |thread| Timeout.timeout(15) { thread.value } }

    expect(results).to all(satisfy { |value| !value.is_a?(Exception) })
    expect(Reminder.find(reminder.id)).to be_cancelled
    expect(Message.outgoing.where("additional_attributes ->> 'touch_id' = ?", reminder.id.to_s)).to be_empty
    expect(conversation.reload).to be_open
  ensure
    release_execution_lock << true if defined?(release_execution_lock) && release_execution_lock.empty?
    release_cancellation << true if defined?(release_cancellation) && release_cancellation.empty?
    employee_thread&.join
    executor_thread&.join
  end
end
