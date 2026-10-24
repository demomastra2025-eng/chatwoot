# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::EventRecorder, '.record_notification for a reply suggestion' do
  let(:account) { create(:account) }

  def record(started_at: Time.current - 1.5, finished_at: Time.current, **payload)
    described_class.record_notification(
      event_name: 'captain.reply_suggestion.complete', started_at: started_at, finished_at: finished_at,
      payload: { account_id: account.id, request_id: 'suggestion-1', feature: 'reply_suggestion', source: 'reply_suggestion' }.merge(payload)
    )
  end

  it 'persists the outcome event with its status, error, reason, wait in the queue and real duration' do
    event = record(
      status: 'failed', outcome: 'failed', error: true, error_code: 'timeout', reason: 'timeout', queue_wait_ms: 1200,
      runtime_mode: 'captain_runtime', conversation_id: 5, conversation_display_id: 1490, user_id: 137, assistant_id: 84,
      channel_type: 'Channel::Whatsapp', current_agent: 'Сезім', engine: 'agent', total_ms: 62_000, budget_ms: 60_000, stage: 'turn',
      detail: 'deadline_at_turn', tools_called: 3, turns: 4, handoffs_count: 1, stale: false
    )

    expect(event).to have_attributes(
      event_name: 'captain.reply_suggestion.complete', status: 'failed', error: true, error_code: 'timeout', reason: 'timeout',
      queue_wait_ms: 1200, request_id: 'suggestion-1', feature: 'reply_suggestion', source: 'reply_suggestion',
      runtime_mode: 'captain_runtime', conversation_display_id: 1490, assistant_id: 84, channel_type: 'Channel::Whatsapp',
      current_agent: 'Сезім'
    )
    expect(event.duration_ms).to be_between(1400, 1600)
    expect(event.payload).to include(
      'outcome' => 'failed', 'engine' => 'agent', 'total_ms' => 62_000, 'budget_ms' => 60_000, 'stage' => 'turn', 'detail' => 'deadline_at_turn',
      'tools_called' => 3, 'turns' => 4, 'handoffs_count' => 1, 'stale' => false
    )
  end

  it 'persists the reason of a no_reply and a human_needed' do
    event = record(status: 'human_needed', outcome: 'human_needed', error: false, reason: 'agent', reason_preview: 'Решает врач.', engine: 'agent')

    expect(event).to have_attributes(status: 'human_needed', error: false, reason: 'agent')
    expect(event.payload).to include('reason_preview' => 'Решает врач.')
  end

  it 'persists a rejected request as unavailable, with the code in the reason' do
    event = record(status: 'unavailable', outcome: 'unavailable', error: false, reason: 'voice_channel_unsupported')

    expect(event).to have_attributes(status: 'unavailable', reason: 'voice_channel_unsupported', error: false)
  end

  it 'keeps the texts of the feedback of a manager when the payload is over its budget' do
    event = described_class.record_notification(
      event_name: 'llm.copilot.feedback', started_at: Time.current, finished_at: Time.current,
      payload: { account_id: account.id, request_id: 'suggestion-1', status: 'sent', suggestion_text: 'Т' * 1500, final_text: 'Ф' * 1500,
                 filler: 'x' * 9000, more_filler: 'y' * 9000, next_message_id: 12 }
    )

    expect(event.payload).to include('payload_truncated' => true, 'suggestion_text' => 'Т' * 1500, 'final_text' => 'Ф' * 1500)
    expect(event.payload).to include('next_message_id' => 12)
    expect(event.payload).not_to have_key('filler')
  end
end
