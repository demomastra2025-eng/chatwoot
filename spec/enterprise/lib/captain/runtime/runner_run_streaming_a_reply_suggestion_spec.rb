# frozen_string_literal: true

require 'rails_helper'

# A read tool of a clinic agent.
StreamedSuggestionSpecTool = Class.new(Captain::Runtime::Tool) do
  params(type: 'object', properties: { query: { type: 'string' } }, required: [], additionalProperties: true)

  attr_reader :executions

  def initialize
    super
    @executions = []
  end

  def name = 'faq_lookup'
  def description = 'Spec faq_lookup'
  def metadata = { read_only: true, risk_level: 'low' }

  def perform(_tool_context, **arguments)
    @executions << arguments
    'Приём терапевта стоит 8000 тенге.'
  end
end

# The agent of a reply suggestion streams its answer through the real RubyLLM chat (only the HTTP answers of the provider are
# scripted, as server-sent events). The runner hands the pieces of the text to the listener of the run, and what comes out of the run
# is the message it would have had without streaming.
RSpec.describe Captain::Runtime::Runner, '#run streaming a reply suggestion' do
  let(:account) { create(:account) }
  let(:model) { 'vendor/stream-model' }
  let(:model_config) do
    {
      'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[structured_output tool_calling tool_choice streaming],
      'supported_parameters' => %w[temperature tools tool_choice response_format structured_outputs]
    }
  end
  let(:llm_context) do
    RubyLLM.context do |config|
      config.openrouter_api_key = 'test-only-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
    end
  end
  let(:requests) { [] }
  let(:tool) { StreamedSuggestionSpecTool.new }
  let(:agent) do
    Captain::Runtime::Agent.new(name: 'assistant_agent', model: model, instructions: 'Clinic', tools: [tool],
                                response_schema: Captain::SuggestionResponseSchema)
  end
  let(:draft) { "Здравствуйте, Анна!\nПриём терапевта стоит \"8000\" тенге, есть время завтра в 10:00. 😀" }
  let(:final_answer) do
    { patient_language: 'ru', response: draft, response_mode: 'reply', operator_note: '', reasoning: 'по прайсу', artifact_ids: [] }
  end
  let(:pieces) { [] }
  let(:listener) { ->(_agent_name, text, _context) { pieces << text } }

  def chunk(delta, finish_reason = nil)
    { id: 'gen-stream-1', model: model, choices: [{ index: 0, delta: delta, finish_reason: finish_reason }] }
  end

  def usage_chunk
    { id: 'gen-stream-1', model: model, choices: [], usage: { prompt_tokens: 1000, completion_tokens: 20, total_tokens: 1020 } }
  end

  def server_sent(*events)
    (events.map { |event| "data: #{event.to_json}\n\n" } + ["data: [DONE]\n\n"]).join
  end

  # The answer as the provider streams it: a few characters at a time.
  def streamed_answer(json, size: 7)
    pieces = json.scan(/.{1,#{size}}/m).map { |piece| chunk({ content: piece }) }
    server_sent(chunk({ role: 'assistant', content: '' }), *pieces, chunk({}, 'stop'), usage_chunk)
  end

  def streamed_tool_call
    start = { tool_calls: [{ index: 0, id: 'call_0', type: 'function', function: { name: 'faq_lookup', arguments: '' } }] }
    fragments = ['{"query":', '"цена приёма"}'].map { |text| chunk({ tool_calls: [{ index: 0, function: { arguments: text } }] }) }
    server_sent(chunk({ role: 'assistant', content: nil }), chunk(start), *fragments, chunk({}, 'tool_calls'), usage_chunk)
  end

  def whole_answer(json)
    { id: 'gen-stream-1', model: model, choices: [{ index: 0, message: { role: 'assistant', content: json }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 1000, completion_tokens: 20 } }.to_json
  end

  def stub_provider(*bodies, type: 'text/event-stream')
    responses = bodies.map { |body| { status: 200, headers: { 'Content-Type' => type, 'X-Generation-Id' => 'gen-stream-1' }, body: body } }
    stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
      .with { |http_request| requests << JSON.parse(http_request.body) }
      .to_return(*responses)
  end

  def run_as(source, callbacks: {}, context: {})
    state = { source: source }
    session = Captain::Conversation::AgentSession.new(entry: build_stubbed(:captain_assistant))
    options = { context: { state: state, agent_session: session }.merge(context), registry: { agent.name => agent }, llm_context: llm_context,
                account: account, callbacks: callbacks }
    described_class.new.run(agent, 'Сколько стоит приём терапевта?', **options)
  end

  def suggest(**)
    run_as('reply_suggestion', callbacks: { answer_delta: [listener] }, **)
  end

  before do
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
    allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
    allow(Llm::Models).to receive(:model_config).and_call_original
    allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
    allow(Llm::Models).to receive(:supports?).and_return(true)
  end

  describe 'the answer step' do
    it 'asks the provider to stream and hands the pieces of the answer to the listener' do
      stub_provider(streamed_answer(final_answer.to_json))

      suggest

      expect(requests.size).to eq(1)
      expect(requests.first).to include('stream' => true, 'stream_options' => { 'include_usage' => true })
      expect(pieces.size).to be > 5
      expect(pieces.join).to eq(final_answer.to_json)
    end

    it 'ends with the same message as the same answer without streaming' do
      stub_provider(streamed_answer(final_answer.to_json))
      streamed = suggest

      WebMock.reset!
      stub_provider(whole_answer(final_answer.to_json), type: 'application/json')
      whole = run_as('reply_suggestion')

      expect(streamed.error).to be_nil
      expect(streamed.output).to eq(whole.output)
      expect(streamed.output['response']).to eq(draft)
      expect(streamed.output['response_mode']).to eq('reply')
      expect(streamed.usage.input_tokens).to eq(whole.usage.input_tokens)
      expect(requests.last).to include('stream' => false)
    end

    it 'leaves the repair of malformed JSON out of the request, which the provider does for a complete response only' do
      stub_provider(streamed_answer(final_answer.to_json))
      suggest
      WebMock.reset!
      stub_provider(whole_answer(final_answer.to_json), type: 'application/json')
      run_as('reply_suggestion')

      expect(Array(requests.first['plugins']).pluck('id')).not_to include('response-healing')
      expect(Array(requests.last['plugins']).pluck('id')).to include('response-healing')
    end

    it 'asks the model the same thing: the request differs from the one without streaming only in the stream settings and that plugin' do
      stub_provider(streamed_answer(final_answer.to_json))
      suggest
      WebMock.reset!
      stub_provider(whole_answer(final_answer.to_json), type: 'application/json')
      run_as('reply_suggestion')
      streamed, whole = requests

      expect(streamed.except('stream', 'stream_options', 'plugins')).to eq(whole.except('stream', 'plugins'))
      expect(streamed['plugins'].to_a.pluck('id') - ['response-healing']).to eq(whole['plugins'].to_a.pluck('id') - ['response-healing'])
    end
  end

  describe 'a step with a tool before the answer' do
    it 'streams every step of the call, hands the listener only the text, and runs the tool once' do
      stub_provider(streamed_tool_call, streamed_answer(final_answer.to_json))

      result = suggest

      expect(requests.size).to eq(2)
      expect(requests.pluck('stream')).to eq([true, true])
      expect(tool.executions).to eq([{ query: 'цена приёма' }])
      expect(pieces.join).to eq(final_answer.to_json)
      expect(result.error).to be_nil
      expect(result.output['response']).to eq(draft)
    end
  end

  describe 'when nobody should see the text as it is written' do
    it 'does not stream when nothing listens' do
      stub_provider(whole_answer(final_answer.to_json), type: 'application/json')

      result = run_as('reply_suggestion')

      expect(requests.first).to include('stream' => false)
      expect(result.output['response']).to eq(draft)
    end

    it 'does not stream a live conversation, listener or not' do
      stub_provider(whole_answer(final_answer.to_json), type: 'application/json')

      run_as('incoming_message', callbacks: { answer_delta: [listener] })

      expect(requests.first).to include('stream' => false)
      expect(pieces).to be_empty
    end

    it 'does not stream the part of a council: its text is not the answer' do
      stub_provider(whole_answer(final_answer.to_json), type: 'application/json')

      suggest(context: { part_run: true })

      expect(requests.first).to include('stream' => false)
      expect(pieces).to be_empty
    end
  end

  describe 'a listener that fails' do
    let(:listener) { ->(*) { raise 'broken listener' } }

    it 'does not break the call: the run ends with the answer' do
      stub_provider(streamed_answer(final_answer.to_json))
      allow(Rails.logger).to receive(:warn)

      result = suggest

      expect(result.error).to be_nil
      expect(result.output['response']).to eq(draft)
    end
  end
end
