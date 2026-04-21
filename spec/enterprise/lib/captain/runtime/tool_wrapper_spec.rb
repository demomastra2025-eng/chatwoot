# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::ToolWrapper do
  class ToolWrapperSpecTool < Captain::Runtime::Tool
    def name
      'tool_wrapper_spec'
    end

    def description
      'Tool wrapper spec tool'
    end

    def perform(_tool_context, **params)
      params.fetch(:result, 'ok')
    end
  end

  class ToolWrapperSpecHaltingTool < Captain::Runtime::Tool
    def name
      'tool_wrapper_halting_spec'
    end

    def description
      'Tool wrapper halting spec tool'
    end

    def perform(_tool_context, **_params)
      halt('Transferred to specialist')
    end
  end

  let(:events) { [] }
  let(:context_wrapper) do
    Captain::Runtime::RunContext.new(
      {
        state: {
          captain_runtime: runtime_preferences
        }
      },
      callbacks: {
        tool_start: [->(tool_name, args, _context) { events << [:start, tool_name, args] }],
        tool_complete: [->(tool_name, result, _context) { events << [:complete, tool_name, result] }]
      }
    )
  end
  let(:runtime_preferences) { {} }
  let(:tool) { ToolWrapperSpecTool.new }
  let(:wrapper) { described_class.new(tool, context_wrapper) }

  it 'returns a controlled tool error when arguments are blocked by safety policy' do
    allow(Llm::SafetyPolicy).to receive(:check!).and_raise(
      Llm::SafetyPolicy::UnsafeContentError.new(
        feature: :assistant,
        stage: :tool_arguments,
        reason: :custom_blocklist,
        rule: 'forbidden'
      )
    )

    result = wrapper.call(query: 'forbidden')

    expect(result).to eq('ERROR: Tool arguments blocked by safety policy')
    expect(events).to include([:start, 'tool_wrapper_spec', { query: 'forbidden' }])

    completion_event = events.last
    expect(completion_event[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(completion_event[2]).to include(
      success: false,
      error: 'ERROR: Tool arguments blocked by safety policy',
      retryable: false
    )
  end

  it 'returns a controlled tool error when results are blocked by safety policy' do
    call_count = 0
    allow(Llm::SafetyPolicy).to receive(:check!) do |stage:, **|
      call_count += 1
      if stage == :tool_results
        raise Llm::SafetyPolicy::UnsafeContentError.new(
          feature: :assistant,
          stage: :tool_results,
          reason: :custom_blocklist,
          rule: 'classified'
        )
      end

      Llm::SafetyPolicy::CheckResult.new(status: :allowed, feature: :assistant, stage: :tool_arguments)
    end

    result = wrapper.call(result: 'classified payload')

    expect(call_count).to eq(2)
    expect(result).to eq('ERROR: Tool result blocked by safety policy')
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'ERROR: Tool result blocked by safety policy',
      retryable: false
    )
  end

  it 'renders normalized tool failures while preserving structured callback payloads' do
    result = wrapper.call(result: Captain::ToolResult.failure(error: 'Provider timeout', retryable: true))

    expect(result).to eq('ERROR: Provider timeout')
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'Provider timeout',
      retryable: true
    )
  end

  it 'returns halting tool results without coercing them into plain strings' do
    halting_wrapper = described_class.new(ToolWrapperSpecHaltingTool.new, context_wrapper)

    result = halting_wrapper.call({})

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect(result.content).to eq('Transferred to specialist')
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_halting_spec'])
    expect(events.last[2]).to be_a(RubyLLM::Tool::Halt)
  end
end
