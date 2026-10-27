# frozen_string_literal: true

require 'rails_helper'

# Test tool constants intentionally live with the examples that exercise them.
# rubocop:disable Lint/ConstantDefinitionInBlock
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
      additionalProperties: false,
      strict: true
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

  # The appointment tools of the agent as the guards see them: the booking names a person, a change or a cancellation an appointment.
  class ToolWrapperSpecAppointmentTool < Captain::Runtime::Tool
    param :starts_at, type: :string, required: false
    param :resource_id, type: :integer, required: false
    param :service_id, type: :integer, required: false
    param :appointment_id, type: :integer, required: false
    param :patient, type: 'object', required: false
    param :reason, type: :string, required: false

    attr_reader :calls

    def initialize(tool_name: 'create_appointment')
      super()
      @tool_name = tool_name
      @calls = 0
    end

    def name
      @tool_name
    end

    def description
      'Tool wrapper appointment spec tool'
    end

    def metadata
      { risk_level: 'high', idempotent: false }
    end

    def perform(_tool_context, **params)
      @calls += 1
      Captain::ToolResult.success(message: "done #{params[:starts_at]}", data: { id: @calls, patient: params[:patient], appointment_id: params[:appointment_id] })
    end
  end

  class ToolWrapperSpecSchedulingTool < Captain::Runtime::Tool
    param :service_id, type: :integer, required: false
    param :resource_ids, type: :array, required: false

    attr_reader :calls
    attr_writer :result

    def initialize(tool_name: 'search_available_slots')
      super()
      @tool_name = tool_name
      @calls = 0
    end

    def name
      @tool_name
    end

    def description
      'Scheduling wrapper spec tool'
    end

    def metadata
      { read_only: true, risk_level: 'low' }
    end

    def perform(_tool_context, **params)
      @calls += 1
      @result || params.fetch(:result, 'slots')
    end
  end

  let(:events) { [] }
  let(:requested_calls) { [] }
  let(:context_wrapper) do
    Captain::Runtime::RunContext.new(
      {
        state: {
          captain_scheduling_grounding_guard_enabled: true,
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

  describe 'service-specific scheduling context' do
    let(:scheduling_tool) { ToolWrapperSpecSchedulingTool.new(tool_name: 'account__search_available_slots') }
    let(:scheduling_wrapper) { described_class.new(scheduling_tool, context_wrapper) }

    before do
      allow(Llm::EventBus).to receive(:publish)
    end

    it 'blocks a generic downgrade after a failed service-specific attempt before executing the tool' do
      failure = Captain::ToolResult.failure(error: 'Service is not available for the requested specialists', retryable: false, audit: { error_class: 'business' })
      scheduling_tool.result = failure

      expect_tool_error(scheduling_wrapper.call(service_id: 469, resource_ids: ['157']),
                        'Service is not available for the requested specialists',
                        retryable: false)
      blocked = scheduling_wrapper.call(resource_ids: ['157'])

      expect_tool_error(blocked, 'Service-specific availability requires a confirmed service_id.', retryable: false)
      expect(scheduling_tool.calls).to eq(1)
      expect(events.last[2]).to include(
        success: false,
        data: include(code: 'service_context_required'),
        audit: include(failure_reason: 'service_context_required', provider_call_blocked: true)
      )
      expect(Llm::EventBus).to have_received(:publish)
        .with(
          'captain.generic_after_service_specific_attempt',
          hash_including(tool_name: 'search_available_slots', provider_call_blocked: true)
        )
    end

    it 'allows a generic first call in a fresh run' do
      expect(scheduling_wrapper.call(resource_ids: ['157'])).to eq('slots')
      expect(scheduling_tool.calls).to eq(1)
    end

    it 'allows a different positive service id after a failed service-specific attempt' do
      failure = Captain::ToolResult.failure(error: 'Service is not available for the requested specialists', retryable: false, audit: { error_class: 'business' })
      scheduling_tool.result = failure

      scheduling_wrapper.call(service_id: 469, resource_ids: ['157'])
      scheduling_tool.result = 'confirmed slots'

      expect(scheduling_wrapper.call(service_id: 466, resource_ids: ['151'])).to eq('confirmed slots')
      expect(scheduling_tool.calls).to eq(2)
    end

    it 'reports but does not block the downgrade while the account guard is disabled' do
      shadow_context = Captain::Runtime::RunContext.new(
        { state: { captain_scheduling_grounding_guard_enabled: false } },
        callbacks: { tool_complete: [->(name, result, _context) { events << [:complete, name, result] }] }
      )
      shadow_tool = ToolWrapperSpecSchedulingTool.new
      shadow_wrapper = described_class.new(shadow_tool, shadow_context)
      allow(Llm::EventBus).to receive(:publish)

      shadow_wrapper.call(service_id: 469, resource_ids: ['157'])

      expect(shadow_wrapper.call(resource_ids: ['157'])).to eq('slots')
      expect(shadow_tool.calls).to eq(2)
      expect(Llm::EventBus).to have_received(:publish)
        .with('captain.generic_after_service_specific_attempt', hash_including(enforced: false, provider_call_blocked: false))
    end
  end

  describe 'Captain response run fencing' do
    let(:assistant) { instance_double(Captain::Assistant, id: 42) }
    let(:fenced_context) do
      Captain::Runtime::RunContext.new(
        {
          state: {
            account_id: 7,
            assistant_id: assistant.id,
            conversation: { id: 11 },
            captain_response_fence: { control_generation: 3, last_message_id: 19, buffer_token: 'buffer-token' }
          }
        },
        callbacks: { tool_start: [->(*args) { events << args }] }
      )
    end
    let(:fenced_wrapper) { described_class.new(tool, fenced_context) }
    let(:fence_service) { instance_double(Captain::Conversation::RunFenceService) }

    before do
      allow(Captain::Assistant).to receive(:find_by).with(id: assistant.id).and_return(assistant)
      allow(Captain::Conversation::RunFenceService).to receive(:new)
        .with(assistant: assistant, state: fenced_context.context[:state])
        .and_return(fence_service)
    end

    it 'checks the current run fence before emitting tool_start or executing the tool' do
      expect(fence_service).to receive(:ensure_current!).and_return(nil)

      expect(fenced_wrapper.call(result: 'safe')).to eq('safe')
      expect(events).not_to be_empty
    end

    it 'does not emit tool_start or execute the tool when the response run is stale' do
      allow(fence_service).to receive(:ensure_current!).and_raise(
        Captain::Conversation::ControlGenerationStaleError,
        'Captain response run is stale'
      )
      expect(tool).not_to receive(:execute)

      expect { fenced_wrapper.call(result: 'unsafe') }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      expect(events).to be_empty
    end
  end

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

  it 'keeps omitted optional keys absent while preserving explicit null, false, zero, and empty collections' do
    result = wrapper.call(
      result: 'normalized',
      priority: nil,
      offset: 0,
      enabled: false,
      items: []
    )

    expect(result).to eq('normalized')
    expect(events.first).to eq(
      [:start, 'tool_wrapper_spec', { result: 'normalized', priority: nil, offset: 0, enabled: false, items: [] }]
    )
  end

  it 'exposes optional tool arguments as non-strict provider fields without nested schema strictness' do
    provider_tool = RubyLLM::Providers::OpenAI::Tools.tool_for(wrapper)

    expect(wrapper.params_schema).not_to have_key('strict')
    expect(wrapper.params_schema.dig('properties', 'enabled')).not_to have_key('description')
    expect(wrapper.params_schema.dig('properties', 'enabled', 'type')).to contain_exactly('boolean', 'null')
    expect(provider_tool.dig(:function, :strict)).to be(false)
    expect(provider_tool.dig(:function, :parameters)).not_to have_key('strict')
    expect(provider_tool.dig(:function, :parameters, 'required')).to be_empty
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
    expect(wrapper.params_schema.dig('properties', 'category_id')).to include('minimum' => 1)
    expect(wrapper.params_schema.dig('properties', 'category_id', 'type')).to contain_exactly('integer', 'null')
    expect(wrapper.params_schema.dig('properties', 'category_id')).not_to have_key('description')
    expect(wrapper.params_schema.dig('properties', 'offset')).not_to have_key('minimum')
  end

  it 'adds positive item bounds to numeric id arrays without appending text to the description' do
    allow(tool).to receive(:params_schema).and_return(
      type: 'object',
      properties: {
        resource_ids: { type: 'array', items: { type: 'integer' } },
        values: { type: 'array', items: { type: 'integer' } }
      }
    )

    expect(wrapper.params_schema.dig('properties', 'resource_ids')).not_to have_key('description')
    expect(wrapper.params_schema.dig('properties', 'resource_ids', 'items')).to include('minimum' => 1)
    expect(wrapper.params_schema.dig('properties', 'values', 'items')).not_to have_key('minimum')
  end

  it 'adds no numeric bounds to string id arrays' do
    allow(tool).to receive(:params_schema).and_return(
      type: 'object',
      properties: {
        resource_ids: { type: 'array', items: { type: 'string' } }
      }
    )

    expect(wrapper.params_schema.dig('properties', 'resource_ids')).not_to have_key('description')
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

  it 'names the allowed values when an argument is outside an enum, so that the model can correct the call' do
    allow(tool).to receive(:params_schema).and_return(
      type: 'object', properties: { mode: { type: 'string', enum: %w[council clarify] }, result: { type: 'string' } }
    )

    result = wrapper.call(mode: 'answer')

    expect_tool_error(result, 'Invalid tool arguments at /mode: enum (allowed: council, clarify)', retryable: false)
  end

  it 'preserves an explicit null when the optional schema allows it' do
    result = wrapper.call(result: 'not executed', category_id: nil)

    expect(result).to eq('not executed')
    expect(events.first).to eq([:start, 'tool_wrapper_spec', { result: 'not executed', category_id: nil }])
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

  it 'halts immediately when an executed tool returns a terminal authorization denial' do
    mutating_tool = ToolWrapperSpecMutatingTool.new
    mutating_wrapper = described_class.new(mutating_tool, context_wrapper)
    denial = Captain::ToolResult.failure(
      error: 'Explicit handoff consent is required',
      retryable: false,
      audit: { failure_stage: 'authorization', failure_reason: 'handoff_not_authorized' }
    )
    allow(mutating_tool).to receive(:perform).and_return(denial)

    first_result = mutating_wrapper.call(title: 'First handoff attempt')
    second_result = mutating_wrapper.call(title: 'Changed handoff attempt')

    expect(first_result).to be_a(RubyLLM::Tool::Halt)
    expect(second_result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(first_result, 'Explicit handoff consent is required', retryable: false)
    expect(second_result.content).to eq(first_result.content)
    expect(mutating_tool).to have_received(:perform).once
    expect(events.count { |event| event.first == :start }).to eq(1)
    expect(context_wrapper.context[:captain_v2_terminal_tool_stop]).to include(
      tool_name: 'tool_wrapper_mutating_spec',
      result: include(retryable: false, audit: include(failure_reason: 'handoff_not_authorized'))
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
    failure = Captain::ToolResult.failure(error: 'Invalid stage filters', retryable: false, audit: { error_class: 'business' })

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
      failure = Captain::ToolResult.failure(error: 'Unknown verified entity id', retryable: false, audit: { error_class: 'business' })

      expect_tool_error(read_only_wrapper.call(result: failure, limit: 10), 'Unknown verified entity id', retryable: false)
      terminal_result = read_only_wrapper.call(result: failure, limit: 50)
      expect(terminal_result).to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(terminal_result, described_class::DUPLICATE_FAILED_TOOL_ERROR, retryable: false)
      expect(read_only_tool.calls).to eq(1)
    end
  end

  it 'executes a corrected search_deals offset after a backend pagination failure' do
    account = create(:account)
    account.enable_features!('crm_deals')
    assistant = create(:captain_assistant, account: account)
    conversation = create(:conversation, account: account)
    deal = create(:crm_deal, account: account)
    create(:crm_deal_contact, account: account, deal: deal, contact: conversation.contact)
    context_wrapper.context[:state] = { account_id: account.id, assistant_id: assistant.id, conversation: { id: conversation.id } }
    search_tool = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'search_deals')
    search_wrapper = described_class.new(search_tool, context_wrapper)

    failed_result = search_wrapper.call(offset: -1, limit: 1)
    expect(Captain::ToolResult.error?(failed_result)).to be(true)
    expect(failed_result).to include('offset must be a non-negative integer')
    corrected_result = search_wrapper.call(offset: 0, limit: 1)

    expect(corrected_result).not_to be_a(RubyLLM::Tool::Halt)
    expect(JSON.parse(corrected_result)).to include('shown' => 1, 'offset' => 0, 'total_count' => 1)
    expect(JSON.parse(corrected_result).fetch('deals').pluck('id')).to eq([deal.id])
    expect(events.count { |event| event.first == :start && event[1] == 'search_deals' }).to eq(2)
  end

  it 'does not suppress a changed limit for unrelated read-only tools' do
    read_only_tool = ToolWrapperSpecReadOnlyTool.new
    read_only_wrapper = described_class.new(read_only_tool, context_wrapper)
    failure = Captain::ToolResult.failure(error: 'Page-specific failure', retryable: false, audit: { error_class: 'business' })

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

  it 'blocks scheduling service searches beyond their dedicated budget before tool execution' do
    allow(Llm::EventBus).to receive(:publish)
    search_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'account__search_scheduling_services')
    search_wrapper = described_class.new(search_tool, context_wrapper)
    allowed = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_BY_TOOL.fetch('search_scheduling_services')

    allowed.times do |index|
      expect(search_wrapper.call(result: "search #{index}")).to eq("search #{index}")
    end
    blocked = search_wrapper.call(result: 'over budget')

    expect(blocked).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(blocked, 'Scheduling service search budget exceeded. Use the available service results.', retryable: false)
    expect(search_tool.calls).to eq(allowed)
    expect(events.last[2]).to include(
      success: false,
      data: include(code: 'tool_budget_exceeded', allowed: allowed, attempted: allowed + 1),
      audit: include(failure_reason: 'tool_budget_exceeded')
    )
    expect(Llm::EventBus).to have_received(:publish)
      .with(
        'captain.scheduling_tool_budget_blocked',
        hash_including(tool_name: 'search_scheduling_services', allowed: allowed, attempted: allowed + 1)
      )
  end

  it 'shares the scheduling service budget across canonical and account-prefixed names' do
    canonical_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'search_scheduling_services')
    prefixed_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'account__search_scheduling_services')
    canonical_wrapper = described_class.new(canonical_tool, context_wrapper)
    prefixed_wrapper = described_class.new(prefixed_tool, context_wrapper)
    allowed = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_BY_TOOL.fetch('search_scheduling_services')

    allowed.times do |index|
      wrapper = index.even? ? canonical_wrapper : prefixed_wrapper
      expect(wrapper.call(result: "search #{index}")).to eq("search #{index}")
    end
    blocked = canonical_wrapper.call(result: 'over budget')

    expect(blocked).to be_a(RubyLLM::Tool::Halt)
    expect(canonical_tool.calls + prefixed_tool.calls).to eq(allowed)
    expect(context_wrapper.context.dig(:captain_v2_tool_request_counts, :by_tool, 'search_scheduling_services')).to eq(allowed + 1)
  end

  it 'reports the global limit when the scheduling tool has not exceeded its own budget' do
    wrappers = Array.new(3) do |index|
      described_class.new(ToolWrapperSpecReadOnlyTool.new(tool_name: "global_budget_tool_#{index}"), context_wrapper)
    end
    described_class::MAX_TOOL_REQUESTS_PER_RUN.times do |index|
      wrappers.fetch(index % wrappers.size).call(result: "lookup #{index}")
    end

    search_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'search_scheduling_services')
    result = described_class.new(search_tool, context_wrapper).call(result: 'blocked')

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect_tool_error(result, 'Tool request limit reached. Stop calling tools and answer using the available results.', retryable: false)
    expect(events.last[2]).to include(audit: include(failure_reason: 'tool_request_limit'))
    expect(search_tool.calls).to eq(0)
  end

  it 'reports the third scheduling service search without blocking while the account guard is disabled' do
    allow(Llm::EventBus).to receive(:publish)
    shadow_context = Captain::Runtime::RunContext.new(
      { state: { captain_scheduling_grounding_guard_enabled: false } }
    )
    search_tool = ToolWrapperSpecReadOnlyTool.new(tool_name: 'search_scheduling_services')
    search_wrapper = described_class.new(search_tool, shadow_context)
    allowed = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_BY_TOOL.fetch('search_scheduling_services')

    (allowed + 1).times { |index| expect(search_wrapper.call(result: "search #{index}")).to eq("search #{index}") }

    expect(search_tool.calls).to eq(allowed + 1)
    expect(Llm::EventBus).to have_received(:publish)
      .with('captain.scheduling_tool_budget_blocked', hash_including(allowed: allowed, attempted: allowed + 1, enforced: false))
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
    failure = Captain::ToolResult.failure(error: 'Permanent lookup failure', retryable: false, audit: { error_class: 'business' })

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

  [Captain::Tools::HandoffTool, Captain::Tools::ResolveConversationTool].each do |terminal_tool_class|
    it "permits #{terminal_tool_class.name} after the run exceeded the ordinary call budget" do
      6.times do |tool_index|
        guard = Captain::Runtime::ToolLoopGuard.new(context_wrapper, "read_#{tool_index}")
        3.times { |index| guard.register_request(signature: "#{tool_index}-#{index}") }
      end
      assistant = create(:captain_assistant)
      conversation = create(:conversation, account: assistant.account, status: :pending)
      context_wrapper.context[:state].merge!(account_id: assistant.account_id, assistant_id: assistant.id,
                                             conversation: { id: conversation.id })
      terminal_tool = terminal_tool_class.new(assistant)
      expect(terminal_tool).to receive(:perform).and_return(Captain::ToolResult.success(message: 'control applied'))

      result = described_class.new(terminal_tool, context_wrapper).call(reason: 'All customer requests were processed')

      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect(result.to_s).to include('control applied')
    end
  end

  it 'stops a later action in the same sequential batch after a human handoff' do
    assistant = create(:captain_assistant, config: { 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['handoff'] } } })
    conversation = create(:conversation, account: assistant.account)
    context_wrapper.context[:state].merge!(account_id: assistant.account_id, assistant_id: assistant.id, conversation: { id: conversation.id })
    context_wrapper.context[:captain_v2_current_tool_batch_id] = 'human-handoff-batch'
    handoff_tool = Captain::Tools::HandoffTool.new(assistant)
    handoff_wrapper = described_class.new(handoff_tool, context_wrapper)
    later_tool = ToolWrapperSpecMutatingTool.new
    later_wrapper = described_class.new(later_tool, context_wrapper)

    handoff_result = handoff_wrapper.call(reason: 'Customer requested a human')
    later_result = later_wrapper.call(title: 'must not create after handoff')

    expect(handoff_result).to be_a(RubyLLM::Tool::Halt)
    expect(context_wrapper.context[:pending_human_handoff]).to include(reason: 'Customer requested a human')
    expect(later_result).to be_a(RubyLLM::Tool::Halt)
    expect(later_result.content).to include('Control has been transferred')
    expect(later_tool.calls).to eq(0)
    expect(events.count { |event| event.first == :start }).to eq(1)
    expect(requested_calls.map(&:first)).to eq([handoff_tool.name])
    expect(context_wrapper.context[:captain_v2_current_tool_batch_id]).to eq('human-handoff-batch')
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

  describe 'correcting a mutation rejected before execution' do
    let(:assistant) { build_stubbed(:captain_assistant) }
    let(:agent_session) { Captain::Conversation::AgentSession.new }
    let(:mutating_tool) { ToolWrapperSpecMutatingTool.new }
    let(:mutating_wrapper) { described_class.new(mutating_tool, context_wrapper) }
    let(:unexecuted_failure) do
      Captain::ToolResult.failure(
        error: 'The appointment date is invalid', retryable: false,
        audit: { failure_stage: 'tool_arguments', mutation_executed: false }
      ).deep_stringify_keys
    end

    before do
      context_wrapper.context[:state].merge!(assistant_id: assistant.id, account_id: assistant.account_id)
      context_wrapper.context[:agent_session] = agent_session
      context_wrapper.context[:agent_request_id] = 'scheduled-request'
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'invalid-arguments-batch'
    end

    # The agent's own actions need no request plan, alone or in a channel with other agents.
    {
      'a lone agent' => ->(assistant) { [{ id: assistant.id }] },
      'an agent with peers' => ->(assistant) { [{ id: assistant.id }, { id: assistant.id + 1 }] }
    }.each do |channel, graph|
      it "executes an own action of #{channel} without a request plan and keeps its receipt under the request scope" do
        context_wrapper.context[:agent_graph] = graph.call(assistant)

        result = mutating_wrapper.call(title: 'Own booking')

        expect(JSON.parse(result)).to include('message' => 'created Own booking')
        expect(mutating_tool.calls).to eq(1)
        expect(context_wrapper.context).not_to include(:part_plan_accepted, :active_part_id)
        expect(agent_session.read.fetch('operations').values).to contain_exactly(
          include('status' => 'finished', 'scope' => 'request:scheduled-request', 'result' => include('success' => true))
        )
        expect(events.map(&:first)).to eq(%i[start complete])
      end
    end

    it 'does not run the same own action twice in one request without a plan' do
      mutating_wrapper.call(title: 'Own booking')
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'repeat-batch'

      repeated = mutating_wrapper.call(title: 'Own booking')

      expect(mutating_tool.calls).to eq(1)
      expect(JSON.parse(repeated)).to include('data' => include('title' => 'Own booking', 'id' => 1))
      expect(agent_session.read.fetch('operations').size).to eq(1)
    end

    describe 'the run of a council part' do
      let(:other_id) { assistant.id + 1 }

      before do
        agent_session.change do |data|
          data['parts'] = [{ 'id' => 'part-1', 'version' => 1, 'executor_agent_id' => assistant.id, 'state' => 'open' }]
        end
        agent_session.update_routing(actor_id: other_id)
        context_wrapper.context.merge!(part_run: true, part_plan_accepted: true, active_part_id: 'part-1', active_part_version: 1,
                                       agent_graph: [{ id: assistant.id }, { id: other_id }])
      end

      it 'lets the owner of the part act with its own mutating tool, without any plan, while another agent holds the conversation' do
        result = mutating_wrapper.call(title: 'Booked by the owner')

        expect(JSON.parse(result)).to include('message' => 'created Booked by the owner')
        expect(mutating_tool.calls).to eq(1)
        expect(agent_session.read.fetch('operations').values).to contain_exactly(
          include('status' => 'finished', 'scope' => 'part:part-1:v1', 'actor_id' => assistant.id, 'outcome' => 'success')
        )
      end

      it 'does not repeat the action of the part: the same call is answered with the stored result, another one is blocked' do
        mutating_wrapper.call(title: 'Booked by the owner')
        context_wrapper.context[:captain_v2_current_tool_batch_id] = 'second-batch'

        again = mutating_wrapper.call(title: 'Booked by the owner')

        expect(JSON.parse(again)).to include('data' => include('title' => 'Booked by the owner'))
        expect(mutating_tool.calls).to eq(1)
      end

      it 'refuses an agent that does not own the part' do
        agent_session.change { |data| data['parts'].first['executor_agent_id'] = other_id }

        expect { mutating_wrapper.call(title: 'Not mine') }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
        expect(mutating_tool.calls).to eq(0)
      end

      it 'keeps the check of the current agent for everyone who is not a part of a council' do
        context_wrapper.context.delete(:part_run)

        expect { mutating_wrapper.call(title: 'Not the current agent') }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      end

      it 'refuses a part whose version was replaced by a newer one' do
        agent_session.change { |data| data['parts'].first['version'] = 2 }

        expect { mutating_wrapper.call(title: 'Old version') }.to raise_error(Captain::Conversation::ControlGenerationStaleError)
      end
    end

    describe 'one agent that acts on several targets in one request' do
      let(:booking_tool) { ToolWrapperSpecAppointmentTool.new }
      let(:booking_wrapper) { described_class.new(booking_tool, context_wrapper) }
      let(:son) { { first_name: 'Test', last_name: 'Son', birth_date: '2016-11-11' } }
      let(:daughter) { { first_name: 'Test', last_name: 'Daughter', birth_date: '2018-03-03' } }
      let(:retry_error) { 'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.' }

      def call_in_new_batch(wrapper, **arguments)
        context_wrapper.context[:captain_v2_current_tool_batch_id] = "batch-#{SecureRandom.hex(4)}"
        wrapper.call(**arguments)
      end

      it 'books the person of the conversation and two relatives, one booking each' do
        results = [{ starts_at: '10:00' }, { starts_at: '10:30', patient: son }, { starts_at: '11:00', patient: daughter }].map do |arguments|
          call_in_new_batch(booking_wrapper, **arguments)
        end

        expect(results.map { |result| JSON.parse(result)['message'] }).to eq(['done 10:00', 'done 10:30', 'done 11:00'])
        expect(booking_tool.calls).to eq(3)
        expect(agent_session.read.fetch('operations').size).to eq(3)
      end

      it 'answers the identical call for a relative with the first result, and refuses the same relative with another time' do
        call_in_new_batch(booking_wrapper, starts_at: '10:30', patient: son)

        identical = call_in_new_batch(booking_wrapper, starts_at: '10:30', patient: son)
        other_time = call_in_new_batch(booking_wrapper, starts_at: '12:00', patient: son)

        expect(JSON.parse(identical)['message']).to eq('done 10:30')
        expect(other_time).to be_a(RubyLLM::Tool::Halt)
        expect_tool_error(other_time, retry_error, retryable: false)
        expect(booking_tool.calls).to eq(1)
      end

      it 'moves and cancels different appointments in one request, and refuses a second change of the same one' do
        move = described_class.new(ToolWrapperSpecAppointmentTool.new(tool_name: 'update_appointment'), context_wrapper)
        cancel = described_class.new(ToolWrapperSpecAppointmentTool.new(tool_name: 'cancel_appointment'), context_wrapper)

        expect(JSON.parse(call_in_new_batch(move, appointment_id: 101, starts_at: '10:00'))['message']).to eq('done 10:00')
        expect(JSON.parse(call_in_new_batch(move, appointment_id: 102, starts_at: '11:00'))['message']).to eq('done 11:00')
        expect(JSON.parse(call_in_new_batch(cancel, appointment_id: 103))['message']).to eq('done ')
        expect(JSON.parse(call_in_new_batch(cancel, appointment_id: 104))['message']).to eq('done ')
        again = call_in_new_batch(move, appointment_id: 101, starts_at: '12:00')

        expect_tool_error(again, retry_error, retryable: false)
      end

      it 'still stops the tool at its limit of requests, whoever the calls are for' do
        described_class::MAX_TOOL_REQUESTS_PER_TOOL.times do |number|
          call_in_new_batch(booking_wrapper, starts_at: '10:00', patient: { first_name: 'Test', last_name: "Child#{number}" })
        end

        over_limit = call_in_new_batch(booking_wrapper, starts_at: '10:00', patient: { first_name: 'Test', last_name: 'Another' })

        expect(over_limit.respond_to?(:content) ? over_limit.content : over_limit).to include('Tool request limit reached')
        expect(booking_tool.calls).to eq(described_class::MAX_TOOL_REQUESTS_PER_TOOL)
      end
    end

    it 'normalizes the failure audit, releases the reservation, and executes corrected arguments in the next batch' do
      allow(mutating_tool).to receive(:perform).and_return(
        unexecuted_failure,
        Captain::ToolResult.success(message: 'Appointment created')
      )

      expect_tool_error(mutating_wrapper.call(title: 'Invalid date'), 'The appointment date is invalid', retryable: false)
      expect(agent_session.read.fetch('operations')).to be_empty
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'corrected-arguments-batch'

      corrected_result = mutating_wrapper.call('name' => mutating_tool.name, 'parameters' => { 'title' => 'Verified date' })

      expect(corrected_result).to eq('Appointment created')
      expect(mutating_tool).to have_received(:perform).with(anything, title: 'Invalid date').once
      expect(mutating_tool).to have_received(:perform).with(anything, title: 'Verified date').once
      expect(agent_session.read.fetch('operations').values).to contain_exactly(
        include('status' => 'finished', 'result' => include('success' => true, 'message' => 'Appointment created'))
      )
    end

    it 'blocks the same normalized invalid arguments even after releasing the operation reservation' do
      allow(mutating_tool).to receive(:perform).and_return(unexecuted_failure)
      mutating_wrapper.call(title: 'Invalid date')
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'repeated-arguments-batch'

      repeated_result = mutating_wrapper.call('name' => mutating_tool.name, 'parameters' => { 'title' => 'Invalid date' })

      expect(repeated_result).to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(repeated_result, described_class::DUPLICATE_FAILED_TOOL_ERROR, retryable: false)
      expect(mutating_tool).to have_received(:perform).once
      expect(agent_session.read.fetch('operations')).to be_empty
    end

    # A business answer is not a failed attempt but the result of the action: the slot is taken, the agent offers or chooses another.
    it 'lets the agent book another slot in the same run after a business answer, and claims the booking that went through' do
      taken = JSON.generate(success: false, reason: 'time_taken')
      allow(mutating_tool).to receive(:perform).and_return(taken, Captain::ToolResult.success(message: 'Appointment created'))

      first = mutating_wrapper.call(title: '10:00')
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'another-slot-batch'
      second = mutating_wrapper.call(title: '11:00')
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'third-slot-batch'
      third = mutating_wrapper.call(title: '12:00')

      expect(first).not_to be_a(RubyLLM::Tool::Halt)
      expect(first).to include('time_taken')
      expect(second).to eq('Appointment created')
      expect(third).to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(third, 'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.',
                        retryable: false)
      expect(mutating_tool).to have_received(:perform).twice
      expect(context_wrapper.context).not_to have_key(:technical_failure)
      expect(agent_session.read.fetch('operations').values).to contain_exactly(include('status' => 'finished', 'outcome' => 'success'))
    end

    it 'lets the agent correct a business answer of the validation of the provider, such as a time outside working hours' do
      outside = JSON.generate(success: false, reason: 'validation_error')
      allow(mutating_tool).to receive(:perform).and_return(outside, Captain::ToolResult.success(message: 'Appointment created'))

      mutating_wrapper.call(title: '23:00')
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'working-hours-batch'

      expect(mutating_wrapper.call(title: '10:00')).to eq('Appointment created')
    end

    {
      'an action that already executed' => { failure_stage: 'tool_arguments', mutation_executed: true },
      'an argument failure without execution evidence' => { failure_stage: 'tool_arguments' }
    }.each do |outcome, audit|
      it "blocks alternate arguments after #{outcome}" do
        failure = Captain::ToolResult.failure(error: 'Action could not be confirmed', retryable: false, audit: audit).deep_stringify_keys
        allow(mutating_tool).to receive(:perform).and_return(failure)
        mutating_wrapper.call(title: 'First attempt')
        context_wrapper.context[:captain_v2_current_tool_batch_id] = 'alternate-arguments-batch'

        alternate_result = mutating_wrapper.call(title: 'Alternate attempt')

        expect(alternate_result).to be_a(RubyLLM::Tool::Halt)
        expect_tool_error(
          alternate_result, 'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.', retryable: false
        )
        expect(mutating_tool).to have_received(:perform).once
        expect(agent_session.read.fetch('operations').values).to contain_exactly(include('status' => 'finished'))
      end
    end

    # A final failure that is no answer to the arguments (the provider rejected the call, an unknown outcome) is technical: the run
    # ends at once, so there is no alternate attempt to block, and nothing else runs after it.
    {
      'an unknown provider outcome' => {},
      'a failure outside argument validation' => { failure_stage: 'provider_request', mutation_executed: false },
      'an unexecuted failure without its validation stage' => { mutation_executed: false }
    }.each do |outcome, audit|
      it "ends the run at once after #{outcome}, and no alternate attempt runs" do
        failure = Captain::ToolResult.failure(error: 'Action could not be confirmed', retryable: false, audit: audit).deep_stringify_keys
        allow(mutating_tool).to receive(:perform).and_return(failure)

        first_result = mutating_wrapper.call(title: 'First attempt')
        context_wrapper.context[:captain_v2_current_tool_batch_id] = 'alternate-arguments-batch'
        alternate_result = mutating_wrapper.call(title: 'Alternate attempt')

        expect(first_result).to be_a(RubyLLM::Tool::Halt)
        expect(alternate_result).to be_a(RubyLLM::Tool::Halt)
        expect(context_wrapper.context[:technical_failure]).to include('tool' => 'tool_wrapper_mutating_spec', 'kind' => 'technical')
        expect(mutating_tool).to have_received(:perform).once
        expect(agent_session.read.fetch('operations').values).to contain_exactly(include('status' => 'finished'))
      end
    end
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

  # A reply suggestion changes nothing in the clinic system: an action tool only prepares an approval card for the operator. A
  # repeated call must not end the run as a technical failure: the operator would get no draft, and the cards would be dropped.
  describe 'in a reply suggestion' do
    let(:mutating_tool) { ToolWrapperSpecMutatingTool.new }
    let(:mutating_wrapper) { described_class.new(mutating_tool, context_wrapper) }
    let(:read_only_tool) { ToolWrapperSpecReadOnlyTool.new }
    let(:read_only_wrapper) { described_class.new(read_only_tool, context_wrapper) }
    let(:cards_key) { Captain::ReplySuggestion::ActionApprovalService::CONTEXT_KEY }
    let(:superseded_key) { Captain::ReplySuggestion::ActionApprovalService::SUPERSEDED_CONTEXT_KEY }
    let(:intercepted) { [] }
    let(:patient) { { first_name: 'Айгуль', last_name: 'Серикова', birth_date: '1990-01-01' } }

    # The approval service as the wrapper sees it: a card per call. The cards it is told to replace, and the booking cards of the same
    # patient, specialist and service (a booking finds them itself), leave the run's list and are remembered as superseded.
    before do
      context_wrapper.context[:state][:source] = 'reply_suggestion'
      allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:intercept) do |tool:, tool_context:, arguments:, replaces: []|
        intercepted << { tool: tool.name, arguments: arguments, replaces: replaces }
        context = tool_context.context
        cards = (context[cards_key] ||= [])
        booking = arguments.slice(:patient, :resource_id, :service_id) if tool.name == 'create_appointment'
        withdrawn = cards.select { |item| replaces.include?(item['action_id']) || (booking && item['booking'] == booking) }
        cards.reject! { |item| withdrawn.include?(item) }
        context[superseded_key] = Array(context[superseded_key]) + withdrawn.pluck('action_id') if withdrawn.any?
        doctor = "doctor-#{arguments[:resource_id]}/#{arguments[:service_id]}" if arguments[:resource_id]
        key = arguments[:title] || [arguments[:appointment_id], doctor, arguments[:starts_at], arguments[:reason]].compact.join(' ')
        card = { 'action_id' => "card-#{key}", 'tool_name' => tool.name, 'status' => 'pending', 'title' => 'Создать задачу',
                 'description' => "Задача: #{key}", 'booking' => booking }.compact
        cards << card
        JSON.generate(success: true, status: 'pending_operator_approval', action_id: card['action_id'], action: tool.name)
      end
    end

    def call_in_new_batch(wrapper, **arguments)
      context_wrapper.context[:captain_v2_current_tool_batch_id] = "batch-#{SecureRandom.hex(4)}"
      wrapper.call(**arguments)
    end

    def card_ids
      context_wrapper.context[cards_key].pluck('action_id')
    end

    it 'prepares a card for another task, and past the card limit names the waiting cards without preparing the new one' do
      titles = ['Перезвонить', 'Отправить анализы', 'Напомнить о приёме']
      results = titles.map { |title| call_in_new_batch(mutating_wrapper, title: title) }

      over_limit = call_in_new_batch(mutating_wrapper, title: 'Перезвонить пациенту завтра')

      expect(results.map { |result| JSON.parse(result)['action_id'] }).to eq(titles.map { |title| "card-#{title}" })
      expect(over_limit).not_to be_a(RubyLLM::Tool::Halt)
      waiting = titles.map { |title| { 'action_id' => "card-#{title}", 'title' => 'Создать задачу', 'description' => "Задача: #{title}" } }
      expect(JSON.parse(over_limit.delete_prefix('ERROR: '))).to eq(
        'error' => described_class::SUGGESTION_CARD_LIMIT_ERROR, 'retryable' => false,
        'data' => { 'status' => 'not_prepared', 'waiting_cards' => waiting }
      )
      expect(intercepted.size).to eq(3)
      expect(card_ids).to eq(titles.map { |title| "card-#{title}" })
      expect(context_wrapper.context).not_to have_key(described_class::TERMINAL_TOOL_STOP_KEY)
    end

    it 'answers an identical repeat of an action with its own card' do
      first = call_in_new_batch(mutating_wrapper, title: 'Перезвонить')
      call_in_new_batch(mutating_wrapper, title: 'Отправить анализы')

      repeat = call_in_new_batch(mutating_wrapper, title: 'Перезвонить')

      expect(repeat).to eq(first)
      expect(intercepted.size).to eq(2)
    end

    def claim_card_ids
      context_wrapper.context[described_class::MUTATING_TOOL_EXECUTIONS_KEY].values.flat_map { |entry| Array(entry[:suggestion_cards]) }
                     .pluck(:action_id)
    end

    # The draft promised one time while the operator approved a card with another, and an operator who approved both cards booked the
    # visit twice: a booking of the same patient with the same specialist and service at a corrected time replaces the earlier card.
    it 'replaces the booking card of the same patient, specialist and service when the booking is repeated with another start',
       :aggregate_failures do
      booking = described_class.new(ToolWrapperSpecAppointmentTool.new, context_wrapper)
      visit = { patient: patient, resource_id: 7, service_id: 3 }

      first = JSON.parse(call_in_new_batch(booking, **visit, starts_at: '2026-10-26T10:00'))
      second = JSON.parse(call_in_new_batch(booking, **visit, starts_at: '2026-10-26T11:30'))

      expect(first['action_id']).to eq('card-doctor-7/3 2026-10-26T10:00')
      expect(second).to include('status' => 'pending_operator_approval', 'action_id' => 'card-doctor-7/3 2026-10-26T11:30')
      expect(card_ids).to eq([second['action_id']])
      expect(claim_card_ids).to eq([second['action_id']])
      expect(context_wrapper.context).not_to have_key(described_class::TERMINAL_TOOL_STOP_KEY)

      # Back to the first time: its answer was withdrawn with its card, so the card is prepared again and replaces the second one.
      third = JSON.parse(call_in_new_batch(booking, **visit, starts_at: '2026-10-26T10:00'))

      expect(intercepted.size).to eq(3)
      expect(third['action_id']).to eq('card-doctor-7/3 2026-10-26T10:00')
      expect(card_ids).to eq([third['action_id']])
      expect(claim_card_ids).to eq([third['action_id']])
    end

    # One message may book the same patient for two visits (an ultrasound and an endocrinologist the same day): a booking with another
    # specialist or service is a card of its own, and only an identical booking is a repeat, answered with its own card.
    it 'prepares a card of its own for a booking of the same patient with another specialist or service' do
      booking = described_class.new(ToolWrapperSpecAppointmentTool.new, context_wrapper)

      ultrasound = JSON.parse(call_in_new_batch(booking, patient: patient, resource_id: 7, service_id: 3, starts_at: '2026-10-26T10:00'))
      endocrinologist = JSON.parse(call_in_new_batch(booking, patient: patient, resource_id: 8, service_id: 4, starts_at: '2026-10-26T11:30'))
      other_service = JSON.parse(call_in_new_batch(booking, patient: patient, resource_id: 7, service_id: 5, starts_at: '2026-10-26T12:00'))
      again = JSON.parse(call_in_new_batch(booking, patient: patient, resource_id: 7, service_id: 3, starts_at: '2026-10-26T10:00'))

      ids = [ultrasound, endocrinologist, other_service].pluck('action_id')
      expect(ids).to eq(['card-doctor-7/3 2026-10-26T10:00', 'card-doctor-8/4 2026-10-26T11:30', 'card-doctor-7/5 2026-10-26T12:00'])
      expect(again['action_id']).to eq(ultrasound['action_id'])
      expect(intercepted.map { |call| call[:replaces] }).to eq([[], [], []])
      expect(card_ids).to eq(ids)
      expect(claim_card_ids).to eq(ids)
      expect(context_wrapper.context[superseded_key]).to be_blank
    end

    # Suggestion eval 26.10, Intermedical: the search listed 14:30 and later and a card was prepared at the 14:20 the patient wrote.
    describe 'a booking at a start that no search of the run returned' do
      # Plain methods, not lets: the group above already has many memoized helpers.
      def account = @account ||= create(:account)
      def resource = @resource ||= create(:scheduling_resource, account: account, name: 'Жанат Есен', timezone: 'Asia/Almaty')
      def booking = @booking ||= described_class.new(ToolWrapperSpecAppointmentTool.new, context_wrapper)
      def search_tool = @search_tool ||= ToolWrapperSpecSchedulingTool.new
      def search = @search ||= described_class.new(search_tool, context_wrapper)

      def answer(*times)
        JSON.generate(success: true, days: [{ resource_id: resource.id, name: resource.name, date: '2026-10-31', times: times, more: 0 }])
      end

      before { context_wrapper.context[:state][:account_id] = account.id }

      it 'refuses the call without preparing a card or claiming the action, and prepares the same call after the exact search',
         :aggregate_failures do
        search_tool.result = answer('14:30', '15:00')
        search.call(resource_ids: [resource.id.to_s])
        arguments = { resource_id: resource.id, starts_at: '2026-10-31T14:20' }

        refused = call_in_new_batch(booking, **arguments)

        expect(refused).not_to be_a(RubyLLM::Tool::Halt)
        expect(refused).to start_with('ERROR:')
        expect(JSON.parse(refused.delete_prefix('ERROR: '))).to include('retryable' => true)
        expect(refused).to include('slot_not_searched', 'from = to = 2026-10-31T14:20')
        expect(intercepted).to be_empty
        expect(context_wrapper.context[described_class::MUTATING_TOOL_EXECUTIONS_KEY].to_h).to be_empty
        expect(context_wrapper.context[described_class::TOOL_FAILURE_CACHE_KEY].to_h).to be_empty

        search_tool.result = answer('14:20')
        search.call(resource_ids: [resource.id.to_s], service_id: 99)
        prepared = JSON.parse(call_in_new_batch(booking, **arguments))

        expect(prepared).to include('status' => 'pending_operator_approval')
        expect(intercepted.size).to eq(1)
      end

      it 'prepares a booking at a start that the search listed, at once' do
        search_tool.result = answer('14:30', '15:00')
        search.call(resource_ids: [resource.id.to_s])

        prepared = JSON.parse(call_in_new_batch(booking, resource_id: resource.id, starts_at: '2026-10-31T15:00'))

        expect(prepared).to include('status' => 'pending_operator_approval')
        expect(intercepted.size).to eq(1)
      end

      it 'refuses a move to such a start in the same way' do
        appointment = create(:scheduling_appointment, account: account, resource: resource, starts_at: Time.zone.parse('2026-10-30T10:00:00+05:00'))
        move = described_class.new(ToolWrapperSpecAppointmentTool.new(tool_name: 'update_appointment'), context_wrapper)

        refused = call_in_new_batch(move, appointment_id: appointment.id, starts_at: '2026-10-31T14:20')

        expect(refused).to include('slot_not_searched')
        expect(intercepted).to be_empty
      end

      it 'holds a booking to a search only for an agent that has the slot search' do
        context_wrapper.context[:current_agent] = 'booker'
        context_wrapper.context[:captain_v2_bound_tool_gate] = true
        context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] = { 'booker' => ['create_appointment'] }
        arguments = { resource_id: resource.id, starts_at: '2026-10-31T14:20' }

        expect(JSON.parse(call_in_new_batch(booking, **arguments))).to include('status' => 'pending_operator_approval')

        context_wrapper.context[:captain_v2_bound_tool_ids_by_agent] = { 'booker' => %w[create_appointment search_available_slots] }
        expect(call_in_new_batch(booking, resource_id: resource.id, starts_at: '2026-10-31T15:00')).to include('slot_not_searched')
      end

      it 'does not guard a live run, where the tool checks the time itself' do
        context_wrapper.context[:state][:source] = 'incoming_message'

        result = call_in_new_batch(booking, resource_id: resource.id, starts_at: '2026-10-31T14:20')

        expect(result).not_to include('slot_not_searched')
        expect(intercepted).to be_empty
      end
    end

    it 'keeps a booking card when the booking that should replace it is refused' do
      booking = described_class.new(ToolWrapperSpecAppointmentTool.new, context_wrapper)
      call_in_new_batch(booking, resource_id: 7, service_id: 3, starts_at: '2026-10-26T10:00')
      allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:intercept)
        .and_return(JSON.generate(success: false, reason: 'schedule_not_open', error_class: 'business'))

      refused = call_in_new_batch(booking, resource_id: 7, service_id: 3, starts_at: '2026-10-26T19:30')

      expect(refused).not_to be_a(RubyLLM::Tool::Halt)
      expect(card_ids).to eq(['card-doctor-7/3 2026-10-26T10:00'])
      expect(context_wrapper.context[described_class::MUTATING_TOOL_EXECUTIONS_KEY]['create_appointment'][:suggestion_cards])
        .to match([hash_including(action_id: 'card-doctor-7/3 2026-10-26T10:00')])
    end

    it 'answers and replaces only the card of the appointment the call is for, never another target or a kept card' do
      kept = { 'action_id' => 'kept-1', 'tool_name' => 'cancel_appointment', 'status' => 'pending', 'title' => 'Отменить запись на приём' }
      context_wrapper.context[cards_key] = [kept]
      cancel = described_class.new(ToolWrapperSpecAppointmentTool.new(tool_name: 'cancel_appointment'), context_wrapper)

      first_a = call_in_new_batch(cancel, appointment_id: 101)
      call_in_new_batch(cancel, appointment_id: 102)
      again_a = call_in_new_batch(cancel, appointment_id: 101)
      corrected_a = JSON.parse(call_in_new_batch(cancel, appointment_id: 101, reason: 'Пациент заболел'))

      expect(JSON.parse(again_a)['action_id']).to eq('card-101')
      expect(again_a).to eq(first_a)
      expect(intercepted.map { |call| call[:replaces] }).to eq([[], [], ['card-101']])
      expect(corrected_a['action_id']).to eq('card-101 Пациент заболел')
      expect(card_ids).to eq(['kept-1', 'card-102', 'card-101 Пациент заболел'])
    end

    it 'shows a refused repeat of an action that has no card to the agent and lets the run go on' do
      allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:intercept)
        .and_return(Captain::ToolResult.failure(error: 'Temporary failure', retryable: true))
      mutating_wrapper.call(title: 'Перезвонить')

      result = mutating_wrapper.call(title: 'Другая задача')

      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(result, 'This action tool already ran in the current assistant run. Do not retry it with alternate arguments.',
                        retryable: false)
      expect(context_wrapper.context).not_to have_key(described_class::TERMINAL_TOOL_STOP_KEY)
    end

    it 'shows a repeated failed call to the agent instead of stopping the run' do
      failure = Captain::ToolResult.failure(error: 'Unknown service', retryable: false, audit: { failure_stage: 'tool_arguments' })
      read_only_wrapper.call(result: failure)

      result = read_only_wrapper.call(result: failure)

      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(result, described_class::DUPLICATE_FAILED_TOOL_ERROR, retryable: false)
      expect(context_wrapper.context).not_to have_key(described_class::TERMINAL_TOOL_STOP_KEY)
    end

    it 'answers a repeated identical read from the first result with a note, and counts every repeat after the first one' do
      results = Array.new(described_class::MAX_TOOL_REQUESTS_PER_TOOL + 1) { read_only_wrapper.call(result: 'Mon 17:00, Mon 18:00') }

      repeated = "Mon 17:00, Mon 18:00\n#{described_class::REPEATED_READ_NOTE}"
      expect(results).to eq(['Mon 17:00, Mon 18:00'] + ([repeated] * described_class::MAX_TOOL_REQUESTS_PER_TOOL))
      expect(read_only_tool.calls).to eq(1)
      expect(context_wrapper.context[described_class::TOOL_REQUEST_COUNTS_KEY][:total]).to eq(described_class::MAX_TOOL_REQUESTS_PER_TOOL)
      expect(events.count { |event| event.first == :complete }).to eq(results.size)
      expect(context_wrapper.context).not_to have_key(described_class::TERMINAL_TOOL_STOP_KEY)

      # A model stuck on the same read stops like any other loop, and the run writes the draft from the results so far.
      stopped = read_only_wrapper.call(result: 'Mon 17:00, Mon 18:00')

      expect(stopped).to be_a(RubyLLM::Tool::Halt).and(have_attributes(content: include('Tool request limit reached')))
      expect(read_only_tool.calls).to eq(1)
    end

    # A slot search over 4 KB, as on PROD. The repeat stays JSON, so the excerpt that replaces it in the history after the next step
    # keeps the slot ids and times, and that excerpt does not invite one more call as the excerpt of a first result does.
    describe 'a repeated JSON read' do
      def excerpts = Captain::Runtime::ToolResultExcerpt

      def slots
        JSON.generate('date' => '2026-10-27', 'slots' => Array.new(80) do |index|
          { 'id' => "slot-#{index}", 'time' => format('%<hour>02d:%<minute>02d', hour: 8 + (index / 6), minute: (index % 6) * 10),
            'doctor' => 'Врач Фамилия Имя Отчество' }
        end)
      end

      it 'stays parseable, with the note in its fields' do
        first = read_only_wrapper.call(result: slots)
        repeated = read_only_wrapper.call(result: slots)

        expect(first).to eq(slots)
        expect(JSON.parse(repeated)).to eq(
          { 'repeated_call' => true, 'repeated_call_note' => described_class::REPEATED_READ_NOTE }.merge(JSON.parse(slots))
        )
        expect(repeated.bytesize).to be > excerpts::THRESHOLD_BYTES
        expect(read_only_tool.calls).to eq(1)
      end

      it 'has an excerpt that keeps the slots and does not ask for another call' do
        first, repeated = Array.new(2) { read_only_wrapper.call(result: slots) }

        marker, summary = excerpts.excerpt(repeated).split("\n", 2)
        expect(marker).to eq(excerpts::REPEATED_MARKER)
        expect(JSON.parse(summary)).to include('repeated_call' => true, 'date' => '2026-10-27')
        expect(JSON.parse(summary)['slots'].first(2)).to eq([{ 'id' => 'slot-0', 'time' => '08:00', 'doctor' => 'Врач Фамилия Имя Отчество' },
                                                             { 'id' => 'slot-1', 'time' => '08:10', 'doctor' => 'Врач Фамилия Имя Отчество' }])
        expect(summary).not_to include(described_class::REPEATED_READ_NOTE)
        expect(excerpts.excerpt(first)).to start_with("#{excerpts::MARKER}\n")
      end
    end

    it 'puts a repeated JSON list under result next to the note' do
      read_only_wrapper.call(result: '[{"id":"slot-1","time":"17:00"}]')

      expect(JSON.parse(read_only_wrapper.call(result: '[{"id":"slot-1","time":"17:00"}]'))).to eq(
        'repeated_call' => true, 'repeated_call_note' => described_class::REPEATED_READ_NOTE, 'result' => [{ 'id' => 'slot-1', 'time' => '17:00' }]
      )
    end

    it 'runs the scheduling guard before the read cache: a generic search after a service-specific one is refused' do
      allow(Llm::EventBus).to receive(:publish)
      scheduling_tool = ToolWrapperSpecSchedulingTool.new
      scheduling_wrapper = described_class.new(scheduling_tool, context_wrapper)

      expect(scheduling_wrapper.call(resource_ids: ['157'])).to eq('slots')
      scheduling_tool.result = 'therapist slots'
      expect(scheduling_wrapper.call(service_id: 469, resource_ids: ['157'])).to eq('therapist slots')
      blocked = scheduling_wrapper.call(resource_ids: ['157'])

      expect_tool_error(blocked, 'Service-specific availability requires a confirmed service_id.', retryable: false)
      expect(scheduling_tool.calls).to eq(2)
      expect(Llm::EventBus).to have_received(:publish)
        .with('captain.generic_after_service_specific_attempt', hash_including(provider_call_blocked: true))
    end

    it 'reads again after a failed read' do
      failure = Captain::ToolResult.failure(error: 'Temporary provider timeout', retryable: true)

      2.times { read_only_wrapper.call(result: failure) }

      expect(read_only_tool.calls).to eq(2)
    end

    it 'keeps the stop of a live run for a repeated action and reads again in a live run' do
      context_wrapper.context[:state][:source] = 'incoming_message'
      2.times { read_only_wrapper.call(result: 'slots') }
      mutating_wrapper.call(title: 'Первая')

      expect(read_only_tool.calls).to eq(2)
      expect(context_wrapper.context).not_to have_key(described_class::SUGGESTION_READ_CACHE_KEY)
      expect(mutating_wrapper.call(title: 'Вторая')).to be_a(RubyLLM::Tool::Halt)
    end
  end

  # PROD 27.10 (7f87f16e9): the model asked for five service searches in ONE step, the fifth was over the budget of four, and its
  # refusal ended the tool loop: the step that writes the draft never came, and a second call without tools (8 s) wrote it instead.
  # The first refusal of a run is the result of the call; only a refusal in a later step ends the run.
  describe 'a refusal of the loop guard in a reply suggestion' do
    let(:read_only_tool) { ToolWrapperSpecReadOnlyTool.new }
    let(:read_only_wrapper) { described_class.new(read_only_tool, context_wrapper) }
    let(:search_tool) { ToolWrapperSpecReadOnlyTool.new(tool_name: 'search_scheduling_services') }
    let(:search_wrapper) { described_class.new(search_tool, context_wrapper) }

    before { context_wrapper.context[:state][:source] = 'reply_suggestion' }

    def budget = Captain::Runtime::ToolLoopGuard::MAX_REQUESTS_BY_TOOL.fetch('search_scheduling_services')
    def budget_error = 'Scheduling service search budget exceeded. Use the available service results.'
    def stop_key = described_class::TERMINAL_TOOL_STOP_KEY

    # A step of the model: the assistant message whose tool calls run together (ChatFactory.track_tool_call_batches!).
    def model_step(id)
      context_wrapper.context[:captain_v2_current_tool_batch_id] = id
    end

    def search_over_the_budget
      model_step('step-1')
      Array.new(budget + 1) { |index| search_wrapper.call(result: "search #{index}") }
    end

    it 'is the result of the call in the first step: the calls after it run and the run goes on' do
      results = search_over_the_budget
      later = read_only_wrapper.call(result: 'contact')

      expect(results.first(budget)).to eq(Array.new(budget) { |index| "search #{index}" })
      expect(results.last).not_to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(results.last, budget_error, retryable: false)
      expect(later).to eq('contact')
      expect(search_tool.calls).to eq(budget)
      expect(context_wrapper.context).not_to have_key(stop_key)
      refusal = events.reverse.find { |event| event.first == :complete && event[1] == 'search_scheduling_services' }
      expect(refusal[2]).to include(success: false, audit: include(failure_reason: 'tool_budget_exceeded'))
    end

    it 'refuses every further call over the budget in that step the same way' do
      results = search_over_the_budget
      results << search_wrapper.call(result: 'search again')

      results.last(2).each { |result| expect_tool_error(result, budget_error, retryable: false) }
      expect(search_tool.calls).to eq(budget)
      expect(context_wrapper.context).not_to have_key(stop_key)
    end

    it 'ends the run when the model asks for more in a later step, and keeps the rest of that step stopped' do
      search_over_the_budget
      model_step('step-2')

      stopped = search_wrapper.call(result: 'one more search')

      expect(stopped).to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(stopped, budget_error, retryable: false)
      expect(context_wrapper.context[stop_key]).to include(tool_name: 'search_scheduling_services')
      expect(read_only_wrapper.call(result: 'contact')).to be_a(RubyLLM::Tool::Halt)
      expect(read_only_tool.calls).to eq(0)
    end

    it 'lets a tool that is within its own budget run in a later step' do
      search_over_the_budget
      model_step('step-2')

      expect(read_only_wrapper.call(result: 'contact')).to eq('contact')
      expect(context_wrapper.context).not_to have_key(stop_key)
    end

    it 'is a first strike for the budget of the whole run, and a stop in a later step' do
      wrappers = Array.new(3) { |index| described_class.new(ToolWrapperSpecReadOnlyTool.new(tool_name: "read_tool_#{index}"), context_wrapper) }
      model_step('step-1')
      described_class::MAX_TOOL_REQUESTS_PER_RUN.times { |index| wrappers.fetch(index % 3).call(result: "lookup #{index}") }

      over_the_run = wrappers.first.call(result: 'one request too many')
      model_step('step-2')
      stopped = wrappers.second.call(result: 'and another one')

      expect(over_the_run).not_to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(over_the_run, 'Tool request limit reached. Stop calling tools and answer using the available results.', retryable: false)
      expect(stopped).to be_a(RubyLLM::Tool::Halt)
    end

    it 'is a first strike for the attempt limit of an identical failing call' do
      failure = Captain::ToolResult.failure(error: 'Temporary provider timeout', retryable: true)
      model_step('step-1')
      described_class::MAX_IDENTICAL_TOOL_EXECUTIONS.times { read_only_wrapper.call(result: failure) }

      refused = read_only_wrapper.call(result: failure)
      model_step('step-2')
      stopped = read_only_wrapper.call(result: failure)

      expect(refused).not_to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(refused, 'Tool execution attempt limit reached. Change the arguments or stop calling this tool.', retryable: false)
      expect(stopped).to be_a(RubyLLM::Tool::Halt)
      expect(read_only_tool.calls).to eq(described_class::MAX_IDENTICAL_TOOL_EXECUTIONS)
    end

    it 'ends the run at once when the steps cannot be told apart' do
      results = Array.new(budget + 1) { |index| search_wrapper.call(result: "search #{index}") }

      expect(results.last).to be_a(RubyLLM::Tool::Halt)
      expect(context_wrapper.context).to have_key(stop_key)
    end

    it 'still ends a live run at the first refusal' do
      context_wrapper.context[:state][:source] = 'incoming_message'

      results = search_over_the_budget

      expect(results.last).to be_a(RubyLLM::Tool::Halt)
      expect(context_wrapper.context).to have_key(stop_key)
    end
  end

  # Suggestion eval 26.10: agents booked visits on a closing «Спасибо». On a turn the router found needs no answer (no_reply_needed)
  # an action refuses, and the run goes on.
  describe 'on a turn that needs no answer' do
    let(:mutating_tool) { ToolWrapperSpecMutatingTool.new }
    let(:read_only_tool) { ToolWrapperSpecReadOnlyTool.new }

    before { context_wrapper.context[described_class::ACKNOWLEDGEMENT_TURN_KEY] = true }

    it 'refuses an action tool without running it and lets the run go on, while a read still answers' do
      result = described_class.new(mutating_tool, context_wrapper).call(title: 'Записать на приём')

      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect_tool_error(result, described_class::ACKNOWLEDGEMENT_ACTION_ERROR, retryable: false)
      expect(mutating_tool.calls).to eq(0)
      expect(context_wrapper.context).not_to have_key(:technical_failure)
      expect(described_class.new(read_only_tool, context_wrapper).call(result: 'Mon 17:00')).to eq('Mon 17:00')
    end

    it 'refuses it in a reply suggestion before any approval card is prepared' do
      context_wrapper.context[:state][:source] = 'reply_suggestion'
      allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:intercept)

      result = described_class.new(mutating_tool, context_wrapper).call(title: 'Записать на приём')

      expect_tool_error(result, described_class::ACKNOWLEDGEMENT_ACTION_ERROR, retryable: false)
      expect(Captain::ReplySuggestion::ActionApprovalService).not_to have_received(:intercept)
    end

    it 'keeps the name of the tool with a cached read of a reply suggestion, for the check of the times a draft offers' do
      context_wrapper.context[:state][:source] = 'reply_suggestion'

      described_class.new(read_only_tool, context_wrapper).call(result: 'Mon 17:00')

      expect(context_wrapper.context[described_class::SUGGESTION_READ_CACHE_KEY].values)
        .to contain_exactly(include(result: 'Mon 17:00', tool: 'tool_wrapper_read_only_spec'))
    end
  end

  describe 'a technical failure of a tool' do
    let(:read_only_tool) { ToolWrapperSpecReadOnlyTool.new(tool_name: 'faq_lookup') }
    let(:read_only_wrapper) { described_class.new(read_only_tool, context_wrapper) }
    let(:mutating_tool) { ToolWrapperSpecMutatingTool.new }
    let(:mutating_wrapper) { described_class.new(mutating_tool, context_wrapper) }
    let(:provider_down) do
      Captain::ToolResult.failure(error: 'Provider did not answer for Айгуль +77010000000', retryable: false,
                                  audit: { failure_stage: 'tool_execution', failure_reason: 'provider_unavailable' })
    end

    before { allow(Captain::Runtime::CoordinationEvents).to receive(:technical_failure) }

    it 'ends the run at once and records what failed, by names and codes only' do
      result = read_only_wrapper.call(result: provider_down)

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(result.content).not_to include('Айгуль', '7701')
      expect(context_wrapper.context[:technical_failure]).to eq(
        'tool' => 'faq_lookup', 'kind' => 'technical', 'stage' => 'tool_execution', 'reason' => 'provider_unavailable', 'mutating' => false
      )
      expect(Captain::Runtime::CoordinationEvents).to have_received(:technical_failure).with(
        context: context_wrapper.context, failure: hash_including('tool' => 'faq_lookup')
      )
    end

    it 'stops every later call of the run, also of another tool, without executing it' do
      read_only_wrapper.call(result: provider_down)
      later = ToolWrapperSpecReadOnlyTool.new(tool_name: 'later_tool')

      expect(described_class.new(later, context_wrapper).call(result: 'must not execute')).to be_a(RubyLLM::Tool::Halt)
      expect(later.calls).to eq(0)
    end

    it 'ends the run for a write with an unknown outcome and keeps its receipt as unknown' do
      assistant = build_stubbed(:captain_assistant)
      session = Captain::Conversation::AgentSession.new
      context_wrapper.context[:state].merge!(assistant_id: assistant.id, account_id: assistant.account_id)
      context_wrapper.context[:agent_session] = session
      context_wrapper.context[:agent_request_id] = 'technical-request'
      allow(mutating_tool).to receive(:perform).and_return(provider_down)

      result = mutating_wrapper.call(title: 'Visit')

      expect(result).to be_a(RubyLLM::Tool::Halt)
      expect(context_wrapper.context[:technical_failure]).to include('tool' => 'tool_wrapper_mutating_spec', 'mutating' => true)
      expect(session.read.fetch('operations').values).to contain_exactly(include('status' => 'finished', 'outcome' => 'unknown'))
      expect(context_wrapper.context[described_class::COMPLETED_ACTIONS_KEY]).to be_nil
    end

    it 'does not end the run for a business outcome: the agent sees it and answers' do
      taken = JSON.generate(success: false, reason: 'time_taken')

      result = read_only_wrapper.call(result: taken)

      expect(result).not_to be_a(RubyLLM::Tool::Halt)
      expect(result).to include('time_taken')
      expect(context_wrapper.context).not_to have_key(:technical_failure)
    end

    it 'does not end the run for a failure that may be retried, or one that declares itself business' do
      retryable = Captain::ToolResult.failure(error: 'Temporary provider timeout', retryable: true)
      declared = Captain::ToolResult.failure(error: 'Patient not found', retryable: false, audit: { error_class: 'business' })

      [retryable, declared].each { |failure| expect(read_only_wrapper.call(result: failure)).not_to be_a(RubyLLM::Tool::Halt) }
      expect(context_wrapper.context).not_to have_key(:technical_failure)
    end

    it 'does not end the run for a lookup of a specialist that does not exist or cannot be scheduled: the agent searches again' do
      reader = Class.new { include Captain::Tools::Account::SchedulingQueryValidation }.new
      missing = reader.send(:scheduling_tool_failure, Scheduling::Error.new(code: 'RESOURCE_NOT_FOUND', message: 'Resource not found',
                                                                           status: :not_found, details: { reason: 'unknown_resource' }))
      bad_ids = reader.send(:scheduling_tool_failure, Scheduling::Error.new(code: 'INVALID_RESOURCE_IDS', message: 'resource_ids must be integers',
                                                                           status: :unprocessable_content,
                                                                           details: { field: 'resource_ids', reason: 'invalid_resource_ids' }))

      [missing, bad_ids].each { |failure| expect(read_only_wrapper.call(result: failure)).not_to be_a(RubyLLM::Tool::Halt) }
      expect(context_wrapper.context).not_to have_key(:technical_failure)
    end

    it 'still ends the run for an internal failure of a scheduling read tool' do
      reader = Class.new { include Captain::Tools::Account::SchedulingQueryValidation }.new
      broken = reader.send(:scheduling_tool_failure, RuntimeError.new('boom'))

      expect(read_only_wrapper.call(result: broken)).to be_a(RubyLLM::Tool::Halt)
      expect(context_wrapper.context[:technical_failure]).to include('tool' => 'faq_lookup', 'kind' => 'technical')
    end

    it 'ends the run for a failure that declares itself technical, however it is marked' do
      declared = Captain::ToolResult.failure(error: 'Provider answered 500', retryable: true, audit: { error_class: 'technical' })

      expect(read_only_wrapper.call(result: declared)).to be_a(RubyLLM::Tool::Halt)
      expect(context_wrapper.context[:technical_failure]).to include('kind' => 'technical')
    end

    it 'ends the run for an exception of a tool, and still raises it' do
      allow(read_only_tool).to receive(:perform).and_raise(RuntimeError, 'boom')

      expect { read_only_wrapper.call(result: 'x') }.to raise_error(RuntimeError, 'boom')
      expect(context_wrapper.context[:technical_failure]).to eq(
        'tool' => 'faq_lookup', 'kind' => 'technical', 'reason' => 'exception', 'error_class' => 'RuntimeError', 'mutating' => false
      )
    end

    it 'leaves a Playground run alone: its failures are scenario outcomes' do
      context_wrapper.context[:playground_session] = Object.new

      expect(read_only_wrapper.send(:reportable_failure_tool?)).to be(false)
    end

    it 'does not end a run for a result that the safety policy blocked, which is no failure of a system' do
      blocked = Captain::ToolResult.failure(error: 'Tool result blocked by safety policy', retryable: false,
                                            audit: { failure_stage: 'tool_results', failure_reason: 'custom_blocklist' })

      expect(read_only_wrapper.call(result: blocked)).not_to be_a(RubyLLM::Tool::Halt)
      expect(context_wrapper.context).not_to have_key(:technical_failure)
    end

    it 'records the actions a run performed, in order, without annotations and failures' do
      annotation = Class.new(ToolWrapperSpecMutatingTool) { def name = 'add_private_note' }.new
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'one'
      mutating_wrapper.call(title: 'Visit')
      context_wrapper.context[:captain_v2_current_tool_batch_id] = 'two'
      described_class.new(annotation, context_wrapper).call(title: 'Note')
      read_only_wrapper.call(result: 'lookup')

      expect(context_wrapper.context[described_class::COMPLETED_ACTIONS_KEY]).to eq(['tool_wrapper_mutating_spec'])
    end
  end

  def expect_tool_error(result, message, retryable:)
    rendered = result.is_a?(RubyLLM::Tool::Halt) ? result.content : result
    payload = JSON.parse(rendered.delete_prefix('ERROR: '))

    expect(payload).to include('error' => message, 'retryable' => retryable)
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock
