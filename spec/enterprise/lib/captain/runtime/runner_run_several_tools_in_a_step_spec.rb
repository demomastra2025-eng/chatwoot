# frozen_string_literal: true

require 'rails_helper'

# A read tool of a clinic agent as the guards of a run see it.
SeveralToolsSpecTool = Class.new(Captain::Runtime::Tool) do
  params(type: 'object', properties: { query: { type: 'string' } }, required: [], additionalProperties: true)

  attr_reader :executions

  def initialize(tool_name)
    super()
    @tool_name = tool_name
    @executions = []
  end

  def name = @tool_name
  def description = "Spec #{@tool_name}"
  def metadata = { read_only: true, risk_level: 'low' }

  def perform(_tool_context, **arguments)
    @executions << arguments
    "#{@tool_name} result for #{arguments[:query] || 'nothing'}"
  end
end

# The model may ask for several tools in ONE step. The request does not forbid it (no parallel_tool_calls: false: the provider default
# applies, and PROD 27.10 showed a step of seven reads), the chat runs the calls of the step one after another, and every call goes
# through its own guards, events and trace. The suggestion counts the steps and the calls of a step. The real RubyLLM chat runs; only
# the HTTP answers of the provider are scripted.
RSpec.describe Captain::Runtime::Runner, '#run' do # rubocop:disable RSpec/MultipleMemoizedHelpers
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:model) { 'vendor/loop-model' }
  let(:model_config) do
    {
      'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[structured_output tool_calling tool_choice],
      'supported_parameters' => %w[temperature tools tool_choice response_format structured_outputs]
    }
  end
  let(:llm_context) do
    RubyLLM.context do |config|
      config.openrouter_api_key = 'test-only-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
    end
  end
  let(:headers) { { 'Content-Type' => 'application/json' } }
  let(:requests) { [] }
  let(:tools) { %w[faq_lookup get_my_contact search_scheduling_services].index_with { |name| SeveralToolsSpecTool.new(name) } }
  let(:agent) do
    Captain::Runtime::Agent.new(name: 'assistant_agent', model: model, instructions: 'Clinic', tools: tools.values,
                                response_schema: Captain::ResponseSchema)
  end
  let(:draft) { 'Приём терапевта стоит 8000 тенге.' }
  let(:final_answer) { { patient_language: 'ru', response: draft, response_mode: 'reply', reasoning: 'ok', artifact_ids: [] } }
  let(:collector) do
    Enterprise::Captain::ReplySuggestionService::TraceCollector.new(
      scope: Captain::ChannelScope.for_conversation(conversation), conversation: conversation, user: user
    )
  end
  let(:events) { [] }
  let(:independent_reads) { %w[faq_lookup get_my_contact search_scheduling_services].zip(['адрес', nil, 'терапевт']) }
  let(:callbacks) do
    {
      llm_step: [forward(:on_llm_step)],
      tool_start: [forward(:on_tool_start), ->(name, *) { events << [:start, name] }],
      tool_complete: [forward(:on_tool_complete), ->(name, *) { events << [:complete, name] }],
      tool_requested: [->(name, *) { events << [:requested, name] }]
    }
  end

  # The suggestion hands its callbacks to the runner the way AgentRunnerService does: the runner calls a proc that calls them.
  def forward(name)
    ->(*args) { collector.callbacks[name].call(*args) }
  end

  def provider_message(message, finish_reason)
    { id: 'gen-1', model: model, choices: [{ index: 0, message: { role: 'assistant' }.merge(message), finish_reason: finish_reason }],
      usage: { prompt_tokens: 1000, completion_tokens: 20 } }.to_json
  end

  def calls_in_one_step(calls)
    tool_calls = calls.each_with_index.map do |(name, query), index|
      { id: "call_#{index}", type: 'function', function: { name: name, arguments: { query: query }.to_json } }
    end
    provider_message({ content: nil, tool_calls: tool_calls }, 'tool_calls')
  end

  def answer = provider_message({ content: final_answer.to_json }, 'stop')

  def stub_provider(*bodies)
    responses = bodies.map { |body| { status: 200, headers: headers, body: body } }
    stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
      .with { |http_request| requests << JSON.parse(http_request.body) }
      .to_return(*responses)
  end

  def suggest
    state = { source: 'reply_suggestion', account_id: account.id, conversation: { id: conversation.id, display_id: conversation.display_id } }
    session = Captain::Conversation::AgentSession.new(conversation: conversation, ephemeral: true)
    options = { context: { state: state, agent_session: session }, registry: { agent.name => agent }, llm_context: llm_context, account: account,
                callbacks: callbacks }
    described_class.new.run(agent, 'Сколько стоит приём терапевта и где вы находитесь?', **options)
  end

  before do
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
    allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
    allow(Llm::Models).to receive(:model_config).and_call_original
    allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
    allow(Llm::Models).to receive(:supports?).and_return(true)
    stub_provider(calls_in_one_step(independent_reads), answer)
  end

  it 'runs the three reads of one step in that step and answers in the next: two requests, no step per tool' do
    result = suggest

    expect(result.error).to be_nil
    expect(result.output).to include('response' => draft)
    expect(requests.size).to eq(2)
    expect(tools.values.map { |tool| tool.executions.size }).to eq([1, 1, 1])
  end

  it 'does not forbid parallel calls in the request: the provider default applies' do
    suggest

    expect(requests.first).not_to have_key('parallel_tool_calls')
    expect(requests.first['tools'].pluck('function').pluck('name')).to match_array(tools.keys)
  end

  it 'sends the results of the three calls back together, in the order of the calls' do
    suggest

    results = requests.last['messages'].select { |message| message['role'] == 'tool' }
    expect(results.pluck('tool_call_id')).to eq(%w[call_0 call_1 call_2])
    expect(results.pluck('content')).to eq(['faq_lookup result for адрес', 'get_my_contact result for nothing',
                                            'search_scheduling_services result for терапевт'])
  end

  it 'puts every call through its own events: requested, start and complete, one after another' do
    suggest

    expect(events).to eq(
      [[:requested, 'faq_lookup'], [:start, 'faq_lookup'], [:complete, 'faq_lookup'],
       [:requested, 'get_my_contact'], [:start, 'get_my_contact'], [:complete, 'get_my_contact'],
       [:requested, 'search_scheduling_services'], [:start, 'search_scheduling_services'], [:complete, 'search_scheduling_services']]
    )
  end

  it 'shows every call as a tool stage of the progress: three starts and three finishes in the trace' do
    suggest
    steps = collector.captain_trace({})['tool_steps']

    expect(steps.map { |step| [step['tool_name'], step['event']] }).to eq(
      [%w[faq_lookup start], %w[faq_lookup finish], %w[get_my_contact start], %w[get_my_contact finish],
       %w[search_scheduling_services start], %w[search_scheduling_services finish]]
    )
  end

  it 'counts the two steps, the one that asked for tools, and the three calls it asked for' do
    suggest

    expect(collector.stats).to include(steps: 2, tool_steps: 1, parallel_steps: 1, max_tools_in_step: 3, tools_called: 3)
  end

  context 'when the model asks for one tool in each step' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    before do
      requests.clear
      stub_request(:post, 'https://openrouter.example/api/v1/chat/completions').to_return(
        { status: 200, headers: headers, body: calls_in_one_step([%w[faq_lookup адрес]]) },
        { status: 200, headers: headers, body: calls_in_one_step([%w[search_scheduling_services терапевт]]) },
        { status: 200, headers: headers, body: answer }
      )
    end

    it 'counts a step for each and no parallel step' do
      suggest

      expect(collector.stats).to include(steps: 3, tool_steps: 2, parallel_steps: 0, max_tools_in_step: 1, tools_called: 2)
    end
  end
end
