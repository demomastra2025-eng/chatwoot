# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::Runtime::ToolWrapper do
  class ToolWrapperSpecTool < Captain::Runtime::Tool
    param :result, type: :string, required: false
    param :category_id, type: :integer, required: false
    param :offset, type: :integer, required: false
    param :enabled, type: :boolean, required: false
    param :items, type: :array, required: false
    param :priority, type: :string, required: false

    params(
      type: 'object',
      properties: {
        result: {},
        category_id: { type: 'integer' },
        offset: { type: 'integer' },
        enabled: { type: 'boolean' },
        items: { type: 'array' },
        priority: { type: 'string' }
      },
      required: [],
      additionalProperties: false
    )

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
    param :result, required: false
    param :limit, type: :integer, required: false
    params(
      type: 'object',
      properties: { result: {}, limit: { type: 'integer' } },
      required: [],
      additionalProperties: false
    )

    attr_reader :calls

    def initialize(tool_name: 'tool_wrapper_read_only_spec')
      super()
      @calls = 0
      @tool_name = tool_name
    end

    def name
      @tool_name
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
    param :title, type: :string, required: true
    param :idempotency_key, type: :string, required: false

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
  let(:requested_calls) { [] }
  let(:context_wrapper) do
    Captain::Runtime::RunContext.new(
      {
        state: {
          captain_runtime: runtime_preferences
        }
      },
      callbacks: {
        tool_requested: [->(tool_name, args, _context) { requested_calls << [tool_name, args] }],
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

  it 'keeps omitted optional keys absent while preserving explicit valid false, zero, and empty collections' do
    result = wrapper.call(
      result: 'normalized',
      offset: 0,
      enabled: false,
      items: []
    )

    expect(result).to eq('normalized')
    expect(events.first).to eq([:start, 'tool_wrapper_spec', { result: 'normalized', offset: 0, enabled: false, items: [] }])
  end

  it 'drops provider null sentinels from optional conversation enum filters before tracing' do
    allow(tool).to receive(:name).and_return('search_conversations')

    result = wrapper.call(result: 'normalized', priority: 'nil')

    expect(result).to eq('normalized')
    expect(events.first).to eq([:start, 'search_conversations', { result: 'normalized' }])
  end

  it 'preserves the same string for unrelated free-text tool arguments' do
    result = wrapper.call(result: 'nil')

    expect(result).to eq('nil')
    expect(events.first).to eq([:start, 'tool_wrapper_spec', { result: 'nil' }])
  end

  it 'adds a positive lower bound to numeric id schemas exposed to the provider' do
    expect(wrapper.params_schema.dig('properties', 'category_id')).to include('type' => 'integer', 'minimum' => 1)
    expect(wrapper.params_schema.dig('properties', 'category_id', 'description')).to include('Never guess an ID')
    expect(wrapper.params_schema.dig('properties', 'offset')).not_to have_key('minimum')
  end

  it 'adds positive item bounds and verified-id guidance to numeric id arrays' do
    allow(tool).to receive(:params_schema).and_return(
      type: 'object',
      properties: {
        resource_ids: { type: 'array', items: { type: 'integer' } },
        values: { type: 'array', items: { type: 'integer' } }
      }
    )

    expect(wrapper.params_schema.dig('properties', 'resource_ids')).to include('description' => include('Never guess an ID'))
    expect(wrapper.params_schema.dig('properties', 'resource_ids', 'items')).to include('minimum' => 1)
    expect(wrapper.params_schema.dig('properties', 'values', 'items')).not_to have_key('minimum')
  end

  it 'adds verified-id guidance without numeric bounds to string id arrays' do
    allow(tool).to receive(:params_schema).and_return(
      type: 'object',
      properties: {
        resource_ids: { type: 'array', items: { type: 'string' } }
      }
    )

    expect(wrapper.params_schema.dig('properties', 'resource_ids')).to include('description' => include('Never guess an ID'))
    expect(wrapper.params_schema.dig('properties', 'resource_ids', 'items')).not_to have_key('minimum')
  end

  it 'rejects an explicit zero id instead of treating it as an omitted value' do
    result = wrapper.call(result: 'not executed', category_id: 0)

    expect_tool_error(result, 'Invalid tool arguments at /category_id: minimum', retryable: false)
    expect(events.last[2]).to include(
      success: false,
      retryable: false,
      audit: include(failure_reason: 'invalid_tool_arguments')
    )
  end

  it 'rejects an explicit null when the schema does not allow null' do
    result = wrapper.call(result: 'not executed', category_id: nil)

    expect_tool_error(result, 'Invalid tool arguments at /category_id: integer', retryable: false)
  end

  it 'preserves an explicit blank string when the schema allows it' do
    wrapper.call(result: '')

    expect(events.first).to eq([:start, 'tool_wrapper_spec', { result: '' }])
  end

  it 'returns a controlled non-retryable error for a malformed provider envelope' do
    result = wrapper.call('name' => 'tool_wrapper_spec', 'parameters' => 'not-an-object')

    expect_tool_error(result, 'Tool call parameters must be an object', retryable: false)
    expect(events.last[2]).to include(
      success: false,
      error: 'Tool call parameters must be an object',
      retryable: false,
      audit: include(failure_reason: 'invalid_tool_arguments')
    )
  end

  it 'returns a controlled error when a tool call is not bound to the current agent' do
    context_wrapper.context[:current_agent] = 'scenario_agent'
    context_wrapper.context[:captain_v2_bound_tool_gate] = true
    context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] = {
      'scenario_agent' => ['allowed_tool']
    }

    result = wrapper.call({})

    expect_tool_error(result, 'Tool is not available for the current agent runtime', retryable: false)
    expect(events).not_to include([:start, 'tool_wrapper_spec', {}])
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

    expect_tool_error(result, 'Tool is not available for the current agent runtime', retryable: false)
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

    expect_tool_error(result, 'Tool is not available for the current agent runtime', retryable: false)
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

    result = wrapper.call(result: 'forbidden')

    expect_tool_error(result, 'Tool arguments blocked by safety policy', retryable: false)
    expect(events).not_to include([:start, 'tool_wrapper_spec', { result: 'forbidden' }])

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
    expect_tool_error(result, 'Tool result blocked by safety policy', retryable: false)
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'ERROR: Tool result blocked by safety policy',
      retryable: false
    )
  end

  it 'renders normalized tool failures while preserving structured callback payloads' do
    result = wrapper.call(result: Captain::ToolResult.failure(error: 'Provider timeout', retryable: true))

    expect_tool_error(result, 'Provider timeout', retryable: true)
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'Provider timeout',
      retryable: true
    )
  end

  it 'reports model requests separately from accepted backend executions' do
    context_wrapper.context[:current_agent] = 'scenario_agent'
    context_wrapper.context[:captain_v2_bound_tool_gate] = true
    context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] = { 'scenario_agent' => [] }

    result = wrapper.call(result: 'not executed')

    expect_tool_error(result, described_class::TOOL_NOT_BOUND_ERROR, retryable: false)
    expect(requested_calls).to contain_exactly(['tool_wrapper_spec', { result: 'not executed' }])
    expect(events.none? { |event| event.first == :start }).to be(true)
  end

  it 'blocks an identical non-retryable failed call instead of executing it repeatedly' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)
    failure = Captain::ToolResult.failure(error: 'Invalid stage filters', retryable: false)

    expect_tool_error(read_only_wrapper.call(result: failure), 'Invalid stage filters', retryable: false)
    terminal_result = read_only_wrapper.call(result: failure)
    expect(terminal_result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(terminal_result, described_class::DUPLICATE_FAILED_TOOL_ERROR, retryable: false)
    expect(read_only_tool.calls).to eq(1)
    expect(events.last[2]).to include(
      success: false,
      error: Captain::Runtime::ToolWrapper::DUPLICATE_FAILED_TOOL_ERROR,
      retryable: false,
      audit: include(failure_reason: 'duplicate_failed_tool_call', original_error: 'Invalid stage filters')
    )
  end

  it 'blocks non-retryable audited lookup failures when only pagination changes' do
    described_class::NON_SEMANTIC_FAILURE_ARGUMENT_KEYS.each_key do |tool_name|
      read_only_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: tool_name)
      isolated_context = Captain::Runtime::RunContext.new({ state: { captain_runtime: runtime_preferences } }, callbacks: {})
      read_only_wrapper = described_class.new(read_only_tool, isolated_context)
      failure = Captain::ToolResult.failure(error: 'Unknown verified entity id', retryable: false)

      expect_tool_error(read_only_wrapper.call(result: failure, limit: 10), 'Unknown verified entity id', retryable: false)
      terminal_result = read_only_wrapper.call(result: failure, limit: 50)
      expect(terminal_result).to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(terminal_result, described_class::DUPLICATE_FAILED_TOOL_ERROR, retryable: false)
      expect(read_only_tool.calls).to eq(1)
    end
  end

  it 'does not suppress a changed limit for unrelated read-only tools' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)
    failure = Captain::ToolResult.failure(error: 'Page-specific failure', retryable: false)

    expect_tool_error(read_only_wrapper.call(result: failure, limit: 10), 'Page-specific failure', retryable: false)
    expect_tool_error(read_only_wrapper.call(result: failure, limit: 50), 'Page-specific failure', retryable: false)
    expect(read_only_tool.calls).to eq(2)
  end

  it 'allows an identical retryable failed call to execute again' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)
    failure = Captain::ToolResult.failure(error: 'Temporary provider timeout', retryable: true)

    2.times { read_only_wrapper.call(result: failure) }

    expect(read_only_tool.calls).to eq(2)
  end

  it 'stops an identical retryable failure after the bounded execution budget' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)
    failure = Captain::ToolResult.failure(error: 'Temporary provider timeout', retryable: true)

    described_class::MAX_IDENTICAL_TOOL_EXECUTIONS.times { read_only_wrapper.call(result: failure) }
    result = read_only_wrapper.call(result: failure)

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(result, 'Tool execution attempt limit reached. Change the arguments or stop calling this tool.', retryable: false)
    expect(read_only_tool.calls).to eq(described_class::MAX_IDENTICAL_TOOL_EXECUTIONS)
    expect(events.last[2]).to include(
      success: false,
      retryable: false,
      audit: include(failure_reason: 'tool_attempt_limit', identical_attempts: described_class::MAX_IDENTICAL_TOOL_EXECUTIONS)
    )
  end

  it 'halts changing arguments after the per-tool request budget' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)

    described_class::MAX_TOOL_REQUESTS_PER_TOOL.times do |index|
      expect(read_only_wrapper.call(result: "lookup #{index}")).to eq("lookup #{index}")
    end
    result = read_only_wrapper.call(result: 'one request too many')

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(result, 'Tool request limit reached. Stop calling tools and answer using the available results.', retryable: false)
    expect(read_only_tool.calls).to eq(described_class::MAX_TOOL_REQUESTS_PER_TOOL)
    expect(context_wrapper.context[:captain_v2_tool_request_counts]).to include(
      total: described_class::MAX_TOOL_REQUESTS_PER_TOOL + 1,
      by_tool: include('tool_wrapper_read_only_spec' => described_class::MAX_TOOL_REQUESTS_PER_TOOL + 1)
    )
    expect(context_wrapper.context[:captain_v2_terminal_tool_stop]).to include(
      tool_name: 'tool_wrapper_read_only_spec',
      result: include(retryable: false, audit: include(failure_reason: 'tool_request_limit'))
    )
  end

  it 'halts the whole run after the global request budget across different tools' do
    wrappers = Array.new(3) do |index|
      described_class.new(ToolWrapperSpecReadOnlyTool.new(tool_name: "read_tool_#{index}"), context_wrapper)
    end

    described_class::MAX_TOOL_REQUESTS_PER_RUN.times do |index|
      wrapper_index = index % wrappers.size
      wrappers.fetch(wrapper_index).call(result: "lookup #{index}")
    end
    result = described_class.new(ToolWrapperSpecReadOnlyTool.new(tool_name: 'final_tool'), context_wrapper).call(result: 'blocked')

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(result, 'Tool request limit reached. Stop calling tools and answer using the available results.', retryable: false)
    expect(context_wrapper.context.dig(:captain_v2_tool_request_counts, :total)).to eq(
      described_class::MAX_TOOL_REQUESTS_PER_RUN + 1
    )
  end

  it 'keeps later calls in the same provider batch halted after a terminal stop' do
    first_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'first_tool')
    later_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'later_tool')
    first_wrapper = described_class.new(first_tool, context_wrapper)
    later_wrapper = described_class.new(later_tool, context_wrapper)
    failure = Captain::ToolResult.failure(error: 'Permanent lookup failure', retryable: false)

    first_wrapper.call(result: failure)
    expect(first_wrapper.call(result: failure)).to be_a(RubyLLM::Tool::Halt)
    result = later_wrapper.call(result: 'must not execute')

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect(later_tool.calls).to eq(0)
    expect(events).to be_none([:start, 'later_tool', { result: 'must not execute' }])
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

  it 'blocks alternate-argument retries of the same mutation across tool-call batches' do
    mutating_tool = ToolWrapperSpecMutatingTool.new
    mutating_wrapper = described_class.new(mutating_tool, context_wrapper)

    mutating_wrapper.call(title: 'First assignee')
    context_wrapper.context[:captain_v2_current_tool_batch_id] = 'next-batch'
    result = mutating_wrapper.call(title: 'Alternate guessed assignee')

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(
      result,
      'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.',
      retryable: false
    )
    expect(mutating_tool.calls).to eq(1)
    expect(events.last[2]).to include(
      success: false,
      retryable: false,
      audit: include(failure_reason: 'mutation_retry_blocked')
    )
  end

  it 'allows a retryable mutation retry with the same explicit idempotency key' do
    mutating_tool = ToolWrapperSpecMutatingTool.new
    mutating_wrapper = described_class.new(mutating_tool, context_wrapper)
    arguments = { title: 'Retry-safe action', idempotency_key: 'intent-123' }
    allow(mutating_tool).to receive(:perform).and_return(
      Captain::ToolResult.failure(error: 'Temporary provider timeout', retryable: true),
      Captain::ToolResult.success(message: 'created Retry-safe action')
    )

    expect_tool_error(mutating_wrapper.call(**arguments), 'Temporary provider timeout', retryable: true)
    expect(mutating_wrapper.call(**arguments)).to eq('created Retry-safe action')
    expect(mutating_tool).to have_received(:perform).twice
  end

  it 'blocks a second mutating tool call in the same assistant tool-call batch' do
    mutating_tool = ToolWrapperSpecMutatingTool.new
    mutating_wrapper = described_class.new(mutating_tool, context_wrapper)
    context_wrapper.context[:captain_v2_current_tool_batch_id] = 'batch-1'
    context_wrapper.context[:captain_v2_mutating_tool_calls_by_batch] = { 'batch-1' => [] }

    first_result = mutating_wrapper.call(title: 'Premium lead')
    second_result = mutating_wrapper.call(title: 'Enterprise lead')

    expect(JSON.parse(first_result)).to include('message' => 'created Premium lead')
    expect_tool_error(second_result, 'Only one action tool can run per assistant tool-call batch', retryable: false)
    expect(mutating_tool.calls).to eq(1)
    expect(events.last[0..1]).to eq([:complete, 'tool_wrapper_mutating_spec'])
    expect(events.last[2]).to include(
      success: false,
      error: 'Only one action tool can run per assistant tool-call batch',
      retryable: false
    )
  end

  it 'atomically reserves one mutating tool call when a batch starts concurrent calls' do
    mutating_tool = ToolWrapperSpecMutatingTool.new
    mutating_wrapper = described_class.new(mutating_tool, context_wrapper)
    context_wrapper.context[:captain_v2_current_tool_batch_id] = 'concurrent-batch'
    context_wrapper.context[:captain_v2_mutating_tool_calls_by_batch] = { 'concurrent-batch' => [] }
    ready = Queue.new
    start = Queue.new

    threads = %w[First Second].map do |title|
      Thread.new do
        ready << true
        start.pop
        mutating_wrapper.call(title: title)
      end
    end
    threads.size.times { ready.pop }
    threads.size.times { start << true }
    results = threads.map(&:value)

    expect(mutating_tool.calls).to eq(1)
    blocked_results = results.select { |result| result.to_s.start_with?('ERROR:') }
    expect(blocked_results.size).to eq(1)
    expect_tool_error(blocked_results.first, 'Only one action tool can run per assistant tool-call batch', retryable: false)
    expect(results.count { |result| result.start_with?('{') }).to eq(1)
  end

  it 'allows repeated read-only tool calls in the same assistant tool-call batch' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)
    context_wrapper.context[:captain_v2_current_tool_batch_id] = 'batch-1'
    context_wrapper.context[:captain_v2_mutating_tool_calls_by_batch] = { 'batch-1' => [] }

    read_only_wrapper.call(result: 'lookup one')
    read_only_wrapper.call(result: 'lookup two')

    expect(read_only_tool.calls).to eq(2)
  end

  it 'does not cache read-only tool calls that can safely execute repeatedly' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)

    read_only_wrapper.call(result: 'lookup one')
    read_only_wrapper.call(result: 'lookup one')

    expect(read_only_tool.calls).to eq(2)
    expect(context_wrapper.context[:captain_v2_tool_result_cache]).to be_blank
  end

  def expect_tool_error(result, message, retryable:)
    rendered = result.is_a?(RubyLLM::Tool::Halt) ? result.content : result
    payload = JSON.parse(rendered.delete_prefix('ERROR: '))

    expect(payload).to include('error' => message, 'retryable' => retryable)
  end
end
