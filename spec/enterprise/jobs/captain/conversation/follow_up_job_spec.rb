require 'rails_helper'

RSpec.describe Captain::Conversation::FollowUpJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) do
    create(
      :captain_assistant,
      account: account,
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'steps' => [
            { 'delay_seconds' => 3600, 'message' => 'Still interested?' },
            { 'delay_seconds' => 10_800, 'message' => 'Can I help?' }
          ]
        }
      }
    )
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :open) }
  let!(:anchor_message) do
    create(
      :message,
      conversation: conversation,
      account: account,
      inbox: inbox,
      sender: assistant,
      message_type: :outgoing,
      content: 'Initial AI response'
    )
  end
  let(:completion_evaluator) { instance_double(Captain::ConversationCompletionEvaluator) }

  before do
    assistant.inboxes << inbox
    allow(Captain::ConversationCompletionEvaluator).to receive(:new).and_return(completion_evaluator)
  end

  it 'schedules each assistant, anchor and step only once' do
    expect do
      2.times do
        described_class.schedule!(
          conversation: conversation,
          assistant: assistant,
          anchor_message: anchor_message,
          step_index: 0,
          delay_seconds: 3600
        )
      end
    end.to change { Reminder.captain_follow_up.count }.by(1)

    expect(Reminder.captain_follow_up.last.idempotency_key).to eq(
      "captain_follow_up:#{assistant.id}:#{anchor_message.id}:0"
    )
  end

  it 'stops when the customer replied after the anchor message' do
    create(
      :message,
      conversation: conversation,
      account: account,
      inbox: inbox,
      message_type: :incoming,
      content: 'Thanks, I have replied'
    )

    expect(completion_evaluator).not_to receive(:perform)
    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.not_to change(conversation.messages, :count)
  end

  it 'sends the configured message and schedules the next step when the conversation is incomplete' do
    allow(completion_evaluator).to receive(:perform).and_return(
      complete: false,
      evaluated: true,
      reason: 'Customer has not replied'
    )

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to change { Reminder.captain_follow_up.count }.by(1)

    follow_up = conversation.messages.order(:id).last
    expect(follow_up.content).to eq('Still interested?')
    expect(follow_up.additional_attributes.dig('captain_follow_up', 'step_index')).to eq(0)
    expect(follow_up.additional_attributes.dig('captain_follow_up', 'mode')).to eq('static')
    scheduled_touch = Reminder.captain_follow_up.last
    expect(scheduled_touch).to be_pending
    expect(scheduled_touch.metadata.dig('captain_follow_up', 'step_index')).to eq(1)
  end

  it 'generates an AI step from current conversation context before sending it' do
    assistant.update!(
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => 'Continue naturally without pressure.',
          'steps' => [
            {
              'delay_seconds' => 3600,
              'mode' => 'ai',
              'objective' => 'Ask whether more information would help'
            }
          ]
        }
      }
    )
    allow(completion_evaluator).to receive(:perform).and_return(
      complete: false,
      evaluated: true,
      reason: 'Customer has not replied'
    )
    generator = instance_double(
      Captain::FollowUpMessageGenerator,
      perform: {
        generated: true,
        message: 'Would any additional information help you decide?',
        reason: 'Matches the configured objective'
      }
    )
    expect(Captain::FollowUpMessageGenerator).to receive(:new).with(
      hash_including(
        account: account,
        assistant: assistant,
        conversation_display_id: conversation.display_id,
        step_index: 0
      )
    ).and_return(generator)

    described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)

    follow_up = conversation.messages.order(:id).last
    expect(follow_up.content).to eq('Would any additional information help you decide?')
    expect(follow_up.additional_attributes.dig('captain_follow_up', 'mode')).to eq('ai')
    expect(follow_up.additional_attributes.dig('captain_follow_up', 'objective')).to eq(
      'Ask whether more information would help'
    )
  end

  it 'raises a retryable error when AI follow-up generation is unavailable' do
    assistant.update!(
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => 'Continue naturally without pressure.',
          'steps' => [
            { 'delay_seconds' => 3600, 'mode' => 'ai', 'objective' => 'Remind the customer' }
          ]
        }
      }
    )
    allow(completion_evaluator).to receive(:perform).and_return(
      complete: false,
      evaluated: true,
      reason: 'Customer has not replied'
    )
    generator = instance_double(
      Captain::FollowUpMessageGenerator,
      perform: { generated: false, error: 'provider_unavailable' }
    )
    allow(Captain::FollowUpMessageGenerator).to receive(:new).and_return(generator)

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to raise_error(Reminders::RetryableExecutionError)

    expect(conversation.messages.count).to eq(1)
  end

  it 'stops when a human agent has replied after the anchor message' do
    create(
      :message,
      conversation: conversation,
      message_type: :outgoing,
      sender: create(:user),
      content: 'I will take it from here.'
    )
    expect(completion_evaluator).not_to receive(:perform)

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.not_to change(conversation.messages, :count)
  end

  it 'stops when the anchor message failed delivery' do
    anchor_message.update!(status: :failed)
    expect(completion_evaluator).not_to receive(:perform)

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.not_to change(conversation.messages, :count)
  end

  it 'does not send a duplicate of a recent outgoing message' do
    create(
      :message,
      conversation: conversation,
      message_type: :outgoing,
      sender: assistant,
      content: '  STILL   INTERESTED? '
    )
    allow(completion_evaluator).to receive(:perform).and_return(
      complete: false,
      evaluated: true,
      reason: 'Customer has not replied'
    )

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.not_to change(conversation.messages, :count)
  end

  it 'creates and schedules a follow-up only once when the same job is delivered repeatedly' do
    allow(completion_evaluator).to receive(:perform).and_return(
      complete: false,
      evaluated: true,
      reason: 'Customer has not replied'
    )

    expect do
      2.times { described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0) }
    end.to change(conversation.messages, :count).by(1)
    expect(Reminder.captain_follow_up.count).to eq(1)
  end

  it 'does not repeat paid AI work when a delivery crashes after generation' do
    assistant.update!(
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => 'Continue naturally.',
          'steps' => [
            { 'delay_seconds' => 3600, 'mode' => 'ai', 'objective' => 'Offer one next action' }
          ]
        }
      }
    )
    allow(completion_evaluator).to receive(:perform).and_return(complete: false, evaluated: true)
    generator = instance_double(
      Captain::FollowUpMessageGenerator,
      perform: { generated: true, message: 'Would more information help?' }
    )
    allow(Captain::FollowUpMessageGenerator).to receive(:new).and_return(generator)
    allow_any_instance_of(described_class).to receive(:find_or_create_follow_up_message).and_raise('simulated crash')

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to raise_error('simulated crash')

    allow_any_instance_of(described_class).to receive(:find_or_create_follow_up_message).and_call_original
    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to change(conversation.messages, :count).by(1)

    expect(completion_evaluator).to have_received(:perform).once
    expect(generator).to have_received(:perform).once
    expect(conversation.messages.order(:id).last.content).to eq('Would more information help?')
    expect(Captain::FollowUpAttempt.find_by(anchor_message: anchor_message).generated_content).to eq(
      'Would more information help?'
    )
    expect(Captain::FollowUpAttempt.find_by(anchor_message: anchor_message)).to be_completed
    expect(anchor_message.reload.additional_attributes).not_to have_key('captain_follow_up_attempts')
  end

  it 'atomically reclaims a failed attempt that has no persisted generated content' do
    assistant.update!(
      config: {
        'follow_up_settings' => {
          'enabled' => true,
          'prompt' => 'Continue naturally.',
          'steps' => [
            { 'delay_seconds' => 3600, 'mode' => 'ai', 'objective' => 'Offer one next action' }
          ]
        }
      }
    )
    allow(completion_evaluator).to receive(:perform).and_return(complete: false, evaluated: true)
    generator = instance_double(
      Captain::FollowUpMessageGenerator,
      perform: { generated: true, message: 'Would more information help?' }
    )
    allow(Captain::FollowUpMessageGenerator).to receive(:new).and_return(generator)
    allow_any_instance_of(described_class).to receive(:persist_processing_content!).and_raise('simulated persistence crash')

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to raise_error('simulated persistence crash')

    attempt = Captain::FollowUpAttempt.find_by!(anchor_message: anchor_message)
    expect(attempt).to be_failed
    expect(attempt.generated_content).to be_blank

    allow_any_instance_of(described_class).to receive(:persist_processing_content!).and_call_original

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to change(conversation.messages, :count).by(1)

    expect(attempt.reload).to be_completed
    expect(conversation.messages.order(:id).last.content).to eq('Would more information help?')
  end

  it 'reclaims the same-key attempt after its processing lease expires' do
    allow(completion_evaluator).to receive(:perform).and_return(complete: false, evaluated: true)
    generator = instance_double(
      Captain::FollowUpMessageGenerator,
      perform: { generated: true, message: 'Would more information help?' }
    )
    allow(Captain::FollowUpMessageGenerator).to receive(:new).and_return(generator)
    allow_any_instance_of(described_class).to receive(:persist_processing_content!).and_raise('simulated worker loss')

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to raise_error('simulated worker loss')

    attempt = Captain::FollowUpAttempt.find_by!(anchor_message: anchor_message)
    attempt.update!(status: :processing, processing_started_at: 2.days.ago, expires_at: 1.day.ago)
    allow_any_instance_of(described_class).to receive(:persist_processing_content!).and_call_original

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to change(conversation.messages, :count).by(1)

    expect(attempt.reload).to be_completed
  end

  it 'prevents a stale cached-content consumer from delivering after another worker reclaims the lease' do
    build_job = lambda do
      described_class.new.tap do |job|
        job.instance_variable_set(:@conversation, conversation)
        job.instance_variable_set(:@assistant, assistant)
        job.instance_variable_set(:@anchor_message, anchor_message)
        job.instance_variable_set(:@step_index, 0)
      end
    end
    stale_job = build_job.call
    attempt = Captain::FollowUpAttempt.create!(
      account: account,
      assistant: assistant,
      conversation: conversation,
      anchor_message: anchor_message,
      step_index: 0,
      attempt_key: stale_job.send(:processing_attempt_key),
      status: :failed,
      generated_content: 'Cached follow-up',
      generated_at: Time.current,
      processing_started_at: 2.days.ago,
      expires_at: 1.hour.from_now
    )

    cached_content = stale_job.send(:claim_cached_processing_content)
    attempt.update!(expires_at: 1.second.ago)
    current_job = build_job.call

    expect(current_job.send(:claim_processing_attempt!)).to be(true)
    expect do
      expect(stale_job.send(:materialize_claimed_follow_up, cached_content)).to eq([false, nil])
    end.not_to change(conversation.messages, :count)
    expect(attempt.reload).to be_processing
  end

  it 'expires stale work without pruning active attempts' do
    allow(completion_evaluator).to receive(:perform).and_return(complete: true, evaluated: true)
    stale_attempt = Captain::FollowUpAttempt.create!(
      account: account,
      assistant: assistant,
      conversation: conversation,
      anchor_message: anchor_message,
      step_index: 4,
      attempt_key: 'stale-attempt',
      status: :processing,
      processing_started_at: 2.days.ago,
      expires_at: 1.day.ago
    )
    active_attempt = Captain::FollowUpAttempt.create!(
      account: account,
      assistant: assistant,
      conversation: conversation,
      anchor_message: anchor_message,
      step_index: 3,
      attempt_key: 'active-attempt',
      status: :processing,
      processing_started_at: Time.current,
      expires_at: 1.day.from_now
    )

    described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)

    expect(stale_attempt.reload).to be_expired
    expect(active_attempt.reload).to be_processing
  end

  it 'raises a retryable error when completion evaluation is unavailable' do
    allow(completion_evaluator).to receive(:perform).and_return(
      complete: false,
      evaluated: false,
      reason: 'Provider unavailable'
    )

    expect do
      described_class.perform_now(conversation.id, assistant.id, anchor_message.id, 0)
    end.to raise_error(Reminders::RetryableExecutionError)

    expect(conversation.messages.count).to eq(1)
  end
end
