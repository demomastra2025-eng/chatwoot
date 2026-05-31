# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::TraceCollector do
  it 'captures only scoped LLM events and sanitizes payloads' do
    collector = described_class.new(trace_id: 'trace-1')
    Llm::EventBus.publish('chat.complete', trace_id: 'outside', token: 'secret')

    collector.capture do
      Llm::EventBus.publish('chat.complete', model: 'openai/gpt-5.4', token: 'secret')
    end

    expect(collector.events.size).to eq(1)
    expect(collector.events.first).to include(event_name: 'llm.chat.complete')
    expect(collector.events.first[:payload]).to include(
      'trace_id' => 'trace-1',
      'model' => 'openai/gpt-5.4',
      'token' => '[REDACTED]'
    )
  end
end
