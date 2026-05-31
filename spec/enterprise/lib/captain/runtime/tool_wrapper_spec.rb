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

  class ToolWrapperSpecReadOnlyTool < Captain::Runtime::Tool
    attr_reader :calls

    def initialize
      super
      @calls = 0
    end

    def name
      'tool_wrapper_read_only_spec'
    end

    def description
      'Tool wrapper read-only spec tool'
    end

    def metadata
      { read_only: true, risk_level: 'low' }
    end

    def perform(_tool_context, **params)
      @calls += 1
      params.fetch(:result, 'ok')
    end
  end

  class ToolWrapperSpecMutatingTool < Captain::Runtime::Tool
    attr_reader :calls

    def initialize
      super
      @calls = 0
    end

    def name
      'tool_wrapper_mutating_spec'
    end

    def description
      'Tool wrapper mutating spec tool'
    end

    def metadata
      { risk_level: 'high', idempotent: false }
    end

    def perform(_tool_context, **params)
      @calls += 1
      Captain::ToolResult.success(message: "created #{params.fetch(:title)}", data: { id: @calls, title: params[:title] })
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

  it 'unwraps provider tool call envelopes before tracing and execution' do
    result = wrapper.call(
      'result' => {
        'name' => 'tool_wrapper_spec',
        'parameters' => { 'result' => 'ok from envelope' }
      }
    )

    expect(result).to eq('ok from envelope')
    expect(events).to include([:start, 'tool_wrapper_spec', { result: 'ok from envelope' }])
  end

  it 'unwraps top-level provider tool call envelopes' do
    result = wrapper.call(
      'name' => 'tool_wrapper_spec',
      'parameters' => { 'result' => 'ok from top-level envelope' }
    )

    expect(result).to eq('ok from top-level envelope')
    expect(events).to include([:start, 'tool_wrapper_spec', { result: 'ok from top-level envelope' }])
  end

  it 'returns a controlled error when a tool call is not bound to the current agent' do
    context_wrapper.context[:current_agent] = 'scenario_agent'
    context_wrapper.context[:captain_v2_bound_tool_gate] = true
    context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] = {
      'scenario_agent' => ['allowed_tool']
    }

    result = wrapper.call({})

    expect(result).to eq('ERROR: Tool is not available for the current agent runtime')
    expect(events).to include([:start, 'tool_wrapper_spec', {}])
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'Tool is not available for the current agent runtime',
      retryable: false
    )
  end

  it 'fails closed when the runtime bound-tool gate has no ids for the current agent' do
    context_wrapper.context[:current_agent] = 'scenario_agent'
    context_wrapper.context[:captain_v2_bound_tool_gate] = true

    result = wrapper.call({})

    expect(result).to eq('ERROR: Tool is not available for the current agent runtime')
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'Tool is not available for the current agent runtime',
      retryable: false
    )
  end

  it 'does not fall back to flat bound ids when current agent has a stale scoped catalog' do
    context_wrapper.context[:current_agent] = 'stale_agent'
    context_wrapper.context[:captain_v2_bound_tool_gate] = true
    context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] = {
      'current_agent' => ['tool_wrapper_spec']
    }
    context_wrapper.context[:captain_v2_bound_tool_ids] = ['tool_wrapper_spec']

    result = wrapper.call({})

    expect(result).to eq('ERROR: Tool is not available for the current agent runtime')
  end

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

  it 'reuses successful mutating tool results for repeated identical calls instead of executing twice' do
    mutating_tool = ToolWrapperSpecMutatingTool.new
    mutating_wrapper = described_class.new(mutating_tool, context_wrapper)

    first_result = mutating_wrapper.call(title: 'Premium lead')
    second_result = mutating_wrapper.call(title: 'Premium lead')

    expect(first_result).to eq(second_result)
    expect(mutating_tool.calls).to eq(1)
    expect(JSON.parse(second_result)).to include(
      'message' => 'created Premium lead',
      'data' => include('id' => 1, 'title' => 'Premium lead')
    )
    expect(context_wrapper.context[:captain_v2_tool_result_cache].values.first).to include(
      tool_name: 'tool_wrapper_mutating_spec',
      arguments: { title: 'Premium lead' },
      result: include(success: true, message: 'created Premium lead')
    )
  end

  it 'does not cache read-only tool calls that can safely execute repeatedly' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)

    read_only_wrapper.call(result: 'lookup one')
    read_only_wrapper.call(result: 'lookup one')

    expect(read_only_tool.calls).to eq(2)
    expect(context_wrapper.context[:captain_v2_tool_result_cache]).to be_blank
  end
end
