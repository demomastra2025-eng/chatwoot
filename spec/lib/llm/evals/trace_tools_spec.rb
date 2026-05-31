# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::TraceTools do
  let(:events) do
    [
      { event_name: 'llm.chat.complete', payload: { model: 'openai/gpt-5.4' } },
      { event_name: 'llm.tool.complete', tool_name: 'update_deal', payload: { result: 'amount 180000' } }
    ]
  end

  it 'expands and searches sanitized trace events' do
    tools = described_class.new(events: events)

    expect(tools.expand_trace(event_name: 'llm.tool.complete')).to include(
      include(event_name: 'llm.tool.complete', tool_name: 'update_deal')
    )
    expect(tools.grep_trace(query: '180000')).to include(
      include(event_name: 'llm.tool.complete')
    )
  end
end
