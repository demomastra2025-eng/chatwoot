# frozen_string_literal: true

require 'rails_helper'

# A read tool of a clinic agent as the guards of a run see it.
ReplySuggestionLoopSpecTool = Class.new(Captain::Runtime::Tool) do
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

# The tool loop of a reply suggestion through the real RubyLLM chat (only the HTTP answers of the provider are scripted).
#
# PROD 27.10 (7f87f16e9), conversation of a clinic: the model asked for seven reads in ONE step, five of them service searches, and the
# scheduling budget is four. The refusal of the fifth ended the tool loop, so the step that writes the draft never came
# ("zero completion", ToolLoopStopped) and a second call without tools wrote it 8 s later. The loop must give the model the refusal as
# the result of the call and let it answer in its next step: two requests, no retry.
RSpec.describe Captain::Runtime::Runner, '#run' do
  let(:account) { create(:account) }
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
  let(:tools) { %w[faq_lookup search_scheduling_services get_my_contact].index_with { |name| ReplySuggestionLoopSpecTool.new(name) } }
  let(:agent) do
    Captain::Runtime::Agent.new(name: 'assistant_agent', model: model, instructions: 'Clinic', tools: tools.values,
                                response_schema: Captain::ResponseSchema)
  end
  let(:draft) { 'Приём терапевта стоит 8000 тенге, есть свободное время завтра в 10:00.' }
  let(:final_answer) do
    { patient_language: 'ru', response: draft, response_mode: 'reply', reasoning: 'по результатам поиска', artifact_ids: [] }
  end
  let(:five_searches) do
    [['faq_lookup', 'цена приёма']] + Array.new(5) { |index| ['search_scheduling_services', "терапевт #{index}"] } + [['get_my_contact', nil]]
  end

  def provider_message(message, finish_reason)
    { id: 'gen-1', model: model, choices: [{ index: 0, message: { role: 'assistant' }.merge(message), finish_reason: finish_reason }],
      usage: { prompt_tokens: 1000, completion_tokens: 20 } }.to_json
  end

  # One assistant message with all these calls: the model asks for them together.
  def calls_in_one_step(calls)
    tool_calls = calls.each_with_index.map do |(name, query), index|
      { id: "call_#{index}", type: 'function', function: { name: name, arguments: { query: query }.to_json } }
    end
    provider_message({ content: nil, tool_calls: tool_calls }, 'tool_calls')
  end

  def answer = provider_message({ content: final_answer.to_json }, 'stop')

  def tool_messages(request)
    request['messages'].select { |message| message['role'] == 'tool' }.pluck('content')
  end

  def stub_provider(*bodies)
    responses = bodies.map { |body| { status: 200, headers: headers, body: body } }
    stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
      .with { |http_request| requests << JSON.parse(http_request.body) }
      .to_return(*responses)
  end

  # The scheduling budget (four searches) is enforced for the accounts that have the grounding guard, as on PROD.
  def run_as(source)
    state = { source: source, captain_scheduling_grounding_guard_enabled: true }
    session = Captain::Conversation::AgentSession.new
    options = { context: { state: state, agent_session: session }, registry: { agent.name => agent }, llm_context: llm_context, account: account }
    described_class.new.run(agent, 'Сколько стоит приём терапевта?', **options)
  end

  def suggest = run_as('reply_suggestion')

  before do
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
    allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
    allow(Llm::Models).to receive(:model_config).and_call_original
    allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
    allow(Llm::Models).to receive(:supports?).and_return(true)
    allow(Llm::EventBus).to receive(:publish).and_call_original
  end

  describe 'the tool loop of a reply suggestion' do
    it 'answers a step of seven calls whose fifth search is over the budget in the next step, with no second call without tools' do
      stub_provider(calls_in_one_step(five_searches), answer)

      result = suggest

      expect(result.error).to be_nil
      expect(result.output).to include('response' => draft)
      expect(requests.size).to eq(2)
      expect(result.context).not_to have_key(Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY)
      expect(result.context).not_to have_key(:technical_failure)
      expect(Llm::EventBus).not_to have_received(:publish).with(/zero_completion/, anything)
    end

    it 'tells the model about the refused search and still runs the read that came after it' do
      stub_provider(calls_in_one_step(five_searches), answer)

      suggest
      results = tool_messages(requests.last)

      expect(results.size).to eq(7)
      expect(results[1..4]).to eq(Array.new(4) { |index| "search_scheduling_services result for терапевт #{index}" })
      expect(results[5]).to include('Scheduling service search budget exceeded. Use the available service results.')
      expect(results[6]).to eq('get_my_contact result for nothing')
      expect(tools['search_scheduling_services'].executions.size).to eq(4)
      expect(tools['get_my_contact'].executions.size).to eq(1)
    end

    it 'still ends a run whose model keeps asking after the refusal: the second call is the stop of the loop' do
      more = calls_in_one_step([['search_scheduling_services', 'ещё один поиск']])
      stub_provider(calls_in_one_step(five_searches), more, answer)

      result = suggest

      expect(requests.size).to eq(2)
      expect(result.error).to be_a(Captain::Runtime::Runner::ToolLoopStopped)
      expect(result.context).to have_key(Captain::Runtime::ToolWrapper::TERMINAL_TOOL_STOP_KEY)
      expect(tools['search_scheduling_services'].executions.size).to eq(4)
    end

    it 'ends a live conversation run at the refusal as before' do
      stub_provider(calls_in_one_step(five_searches), answer)

      result = run_as('incoming_message')

      expect(requests.size).to eq(1)
      expect(result.error).to be_a(Captain::Runtime::Runner::TechnicalFailure)
      expect(result.context[:technical_failure]).to include('reason' => 'tool_loop')
    end
  end
end
