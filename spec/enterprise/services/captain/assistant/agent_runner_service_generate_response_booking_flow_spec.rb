# frozen_string_literal: true

require 'rails_helper'

# A reply suggestion for a patient who asks the price of a service and a free time, through the real runner with the real tools and the
# real database (only the HTTP answers of the model provider and the embeddings are scripted). The model needs ONE tool step instead of
# a chain of three, and no step at all for the patient card, the upcoming visits and the FAQ: they are in the prompt of its first call.
RSpec.describe Captain::Assistant::AgentRunnerService, '#generate_response' do # rubocop:disable RSpec/MultipleMemoizedHelpers
  include ActiveSupport::Testing::TimeHelpers

  # Tuesday, 21 April 2026, 12:00 in Almaty; the specialist receives Monday to Friday 09:00-18:00 every 30 minutes.
  let(:now) { Time.zone.parse('2026-04-21 12:00:00 +0500') }
  let(:model) { 'vendor/loop-model' }
  let(:model_config) do
    {
      'provider' => 'openrouter', 'type' => 'chat', 'capabilities' => %w[structured_output tool_calling tool_choice],
      'supported_parameters' => %w[temperature tools tool_choice response_format structured_outputs]
    }
  end
  let(:tool_ids) do
    %w[get_my_contact list_my_appointments faq_lookup search_scheduling_services search_scheduling_resources search_available_slots]
  end
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, timezone: 'Asia/Almaty') }
  let(:contact) { create(:contact, account: account, name: 'Айгуль', last_name: 'Ахметова', phone_number: '+77010000001') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }
  let(:assistant) do
    create(:captain_assistant, account: account, description: 'Ты администратор клиники.',
                               config: { 'model' => model, 'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => tool_ids } } })
  end
  let(:doctor) { create(:scheduling_resource, account: account, name: 'Асланова Айгерим', timezone: 'Asia/Almaty') }
  let(:ultrasound) { create(:scheduling_service, account: account, name: 'УЗИ щитовидной железы', base_price: 9000, duration_min: 20) }
  let(:embedder) do
    instance_double(Captain::Llm::EmbeddingService, embedding_model: ServiceEmbeddingHelpers::FAKE_MODEL,
                                                    get_embedding: unit_vector(0), get_embeddings: [unit_vector(4)])
  end
  let(:llm_context) do
    RubyLLM.context do |config|
      config.openrouter_api_key = 'test-only-key'
      config.openrouter_api_base = 'https://openrouter.example/api/v1'
    end
  end
  let(:headers) { { 'Content-Type' => 'application/json' } }
  let(:requests) { [] }
  let(:stats) { [] }
  let(:message_history) { [{ role: 'user', content: 'Сколько стоит УЗИ щитовидки и можно завтра?' }] }
  let(:draft) { 'УЗИ щитовидной железы стоит 9000 тенге. Завтра свободно в 09:00, 11:00 и 13:00 у Аслановой Айгерим. Какое время вам подходит?' }

  def provider_message(message, finish_reason)
    { id: 'gen-1', model: model, choices: [{ index: 0, message: { role: 'assistant' }.merge(message), finish_reason: finish_reason }],
      usage: { prompt_tokens: 1000, completion_tokens: 20 } }.to_json
  end

  def booking_search_call
    arguments = { services: ['УЗИ щитовидки'], from: '2026-04-22', to: '2026-04-23' }.to_json
    provider_message({ content: nil, tool_calls: [{ id: 'call_0', type: 'function', function: { name: 'search_booking_options', arguments: arguments } }] },
                     'tool_calls')
  end

  def final_answer
    answer = { patient_language: 'ru', response: draft, response_mode: 'reply', operator_note: '', reasoning: 'цена и время', artifact_ids: [] }
    provider_message({ content: answer.to_json }, 'stop')
  end

  def system_prompt(request)
    request['messages'].find { |message| %w[system developer].include?(message['role']) }['content']
  end

  def tool_names(request)
    request['tools'].pluck('function').pluck('name')
  end

  around { |example| travel_to(now) { example.run } }

  def stub_platform
    allow(Llm::Config).to receive(:initialize!)
    allow(Llm::ApiClient).to receive(:moderate).and_return(instance_double(RubyLLM::Moderation, flagged?: false))
    allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
    allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
    allow(Llm::Models).to receive(:model_config).and_call_original
    allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
    allow(Llm::Models).to receive(:supports?).and_return(true)
    allow(Llm::Models).to receive_messages(valid_model_for?: true, model_selectable_for_feature?: true)
    allow(Captain::Llm::EmbeddingService).to receive(:new).with(account_id: account.id).and_return(embedder)
    allow_any_instance_of(described_class).to receive(:llm_context_for_run).and_return(llm_context) # rubocop:disable RSpec/AnyInstance
  end

  def stub_provider
    stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
      .with { |http_request| requests << JSON.parse(http_request.body) }
      .to_return({ status: 200, headers: headers, body: booking_search_call }, { status: 200, headers: headers, body: final_answer })
  end

  def create_clinic_data
    (1..5).each do |weekday|
      create(:scheduling_work_rule, resource: doctor, account: account, weekday: weekday, start_minute: 9 * 60, end_minute: 18 * 60)
    end
    index_service(ultrasound, vector_at(4, 0.93))
    create(:scheduling_service_price, account: account, service: ultrasound, resource: doctor, price: 9000)
    visit_start = 3.days.from_now
    create(:scheduling_appointment, account: account, contact: contact, resource: doctor, starts_at: visit_start, ends_at: visit_start + 30.minutes)
    create(:captain_assistant_response, account: account, assistant: assistant, question: 'Как подготовиться к УЗИ?', status: 'approved',
                                        answer: 'Не есть за 6 часов.')
      .update_columns(embedding: unit_vector(0), embedding_model: ServiceEmbeddingHelpers::FAKE_MODEL) # rubocop:disable Rails/SkipsModelValidations
  end

  before do
    account.enable_features!('scheduling')
    stub_platform
    create_clinic_data
    stub_provider
  end

  def suggest
    service = described_class.new(assistant: assistant, conversation: conversation, source: 'reply_suggestion', request_id: SecureRandom.uuid,
                                  callbacks: { on_suggestion_preload: ->(preload) { stats << preload } })
    service.generate_response(message_history: message_history)
  end

  it 'drafts the answer in two model steps: one tool step for the whole chain, and nothing for the card, the visits and the FAQ' do
    result = suggest

    expect(result).to include('response' => draft, 'response_mode' => 'reply')
    expect(requests.size).to eq(2)
    expect(stats.first['parts']).to eq(%w[card appointments faq])
  end

  it 'gives the first call the booking search next to the separate tools, and the patient data and the FAQ in the prompt' do
    suggest
    prompt = system_prompt(requests.first)

    expect(tool_names(requests.first)).to include('search_booking_options', 'search_available_slots', 'search_scheduling_resources')
    expect(prompt).to include('call search_booking_options first', 'Patient card on file (data; get_my_contact returns the same)',
                              'Upcoming appointments of the patient and of the patients on the same phone',
                              "# Possibly relevant FAQ\n", '- Q: Как подготовиться к УЗИ?')
    expect(prompt).to include('Не есть за 6 часов.')
  end

  it 'answers the booking search with the services, their specialist and the free times of the day asked for, in the second call' do
    suggest
    result = requests.last['messages'].select { |message| message['role'] == 'tool' }.pluck('content')
    answer = JSON.parse(result.first)

    expect(result.size).to eq(1)
    expect(answer['results'].first).to include('slots_service_id' => ultrasound.id)
    expect(answer['results'].first['services'].first).to include('name' => 'УЗИ щитовидной железы', 'price' => 9000)
    expect(answer['results'].first['days']).to include(include('name' => 'Асланова Айгерим', 'date' => '2026-04-22'))
  end
end
