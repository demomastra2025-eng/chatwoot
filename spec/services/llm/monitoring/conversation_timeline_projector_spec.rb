# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::ConversationTimelineProjector do
  let(:conversation) { create(:conversation) }
  let(:account) { conversation.account }
  let(:event_attributes) do
    {
      account: account,
      conversation: conversation,
      event_name: 'llm.tool.complete',
      feature: 'assistant',
      runtime_mode: 'captain_runtime',
      tool_name: 'search_deals',
      request_id: 'request-123',
      error: false,
      tool_failure: false,
      payload: {
        'started_at' => '2026-08-01T12:35:27.123456Z',
        'completed_at' => '2026-08-01T12:35:28.123456Z',
        'result_success' => true
      }
    }
  end

  it 'persists a visible activity message at the tool event position' do
    account.update!(locale: :ru)
    event = create(:llm_event, **event_attributes, created_at: Time.zone.parse('2026-08-01 12:35:28.5'))

    expect { described_class.new(event).call }.to change { conversation.messages.activity.count }.by(1)

    message = conversation.messages.activity.last
    expect(message).to have_attributes(
      account_id: account.id,
      inbox_id: conversation.inbox_id,
      content: 'ИИ Агент выполнил инструмент «search_deals»',
      private: false,
      created_at: event.created_at
    )
    expect(message.source_id).to start_with('captain-tool:')
    expect(message.content_attributes).to include(
      'data' => include(
        'type' => 'captain_tool_event',
        'event' => 'completed',
        'llm_event_id' => event.id,
        'request_id' => 'request-123',
        'tool_name' => 'search_deals'
      )
    )
  end

  it 'deduplicates repeated telemetry records for the same tool execution' do
    first_event = create(:llm_event, **event_attributes)
    duplicate_event = create(:llm_event, **event_attributes)

    expect do
      described_class.new(first_event).call
      described_class.new(duplicate_event).call
    end.to change { conversation.messages.activity.count }.by(1)
  end

  it 'keeps separate executions of the same tool in the timeline' do
    first_event = create(:llm_event, **event_attributes)
    second_event = create(
      :llm_event,
      **event_attributes.deep_merge(
        payload: {
          'started_at' => '2026-08-01T12:35:27.223456Z',
          'completed_at' => '2026-08-01T12:35:28.223456Z'
        }
      )
    )

    expect do
      described_class.new(first_event).call
      described_class.new(second_event).call
    end.to change { conversation.messages.activity.count }.by(2)
  end

  it 'marks failed tool executions without exposing the result body' do
    event = create(
      :llm_event,
      **event_attributes.deep_merge(
        error: true,
        tool_failure: true,
        payload: { 'result_success' => false, 'result_message' => 'private result' }
      )
    )

    message = described_class.new(event).call

    expect(message.content).to eq('AI Agent tool search_deals failed')
    expect(message.content_attributes.dig('data', 'event')).to eq('failed')
    expect(message.content_attributes.to_json).not_to include('private result')
  end

  it 'ignores events outside the Captain conversation runtime boundary' do
    event = create(:llm_event, **event_attributes, runtime_mode: 'copilot')

    expect { described_class.new(event).call }.not_to change(Message, :count)
  end
end
