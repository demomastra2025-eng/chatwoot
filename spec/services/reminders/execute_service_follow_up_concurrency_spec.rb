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

  it 'retries a second real executor with the same claim while generation is in progress' do
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
          'prompt' => 'Be concise.',
          'steps' => [{ 'mode' => 'static', 'message' => 'Checking in.', 'delay_seconds' => 60 }]
        }
      }
    )
    create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    incoming = create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: 'Question')
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
    evaluator_started = Queue.new
    release_evaluator = Queue.new

    allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_wrap_original do |original, **attributes|
      evaluator = original.call(**attributes)
      allow(evaluator).to receive(:make_api_call) do
        if Thread.current[:hold_follow_up_evaluator]
          evaluator_started << true
          Timeout.timeout(10) { release_evaluator.pop }
        end
        {
          error: nil,
          message: { 'complete' => false, 'reason' => 'The customer has not answered yet' }
        }
      end
      evaluator
    end

    first_executor = in_thread do
      Thread.current[:hold_follow_up_evaluator] = true
      Reminders::ExecuteService.new(reminder: Reminder.find(reminder.id), processing_claim: claim).perform
    end

    wait_for_signal(evaluator_started, first_executor)
    second_result = Reminders::ExecuteService.new(
      reminder: Reminder.find(reminder.id),
      processing_claim: claim
    ).perform

    expect(second_result).to be_a(Reminder)
    expect(Reminder.find(reminder.id)).to have_attributes(status: 'processing', processing_claim_token: claim)
    expect(Reminders::ExecuteReminderJob).to have_been_enqueued.with(reminder.id, claim)

    release_evaluator << true
    first_result = Timeout.timeout(15) { first_executor.value }

    expect(first_result).not_to be_a(Exception)
    expect(Reminder.find(reminder.id)).to be_completed
    expect(Message.outgoing.where("additional_attributes ->> 'touch_id' = ?", reminder.id.to_s).count).to eq(1)
  ensure
    release_evaluator << true if defined?(release_evaluator) && release_evaluator.empty?
    first_executor&.join
  end
end
