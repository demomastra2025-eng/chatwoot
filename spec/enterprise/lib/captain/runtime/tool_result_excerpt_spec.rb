# frozen_string_literal: true

require 'rails_helper'

ExcerptSpecBigTool = Class.new(RubyLLM::Tool) do
  description 'Returns a large catalog answer'
  define_method(:name) { 'search_scheduling_services' }
  define_method(:execute) do
    JSON.generate('services' => Array.new(60) do |index|
      { 'id' => index + 1, 'name' => "Услуга номер #{index + 1} с длинным названием", 'price' => 1000 + index }
    end)
  end
end

ExcerptSpecSmallTool = Class.new(RubyLLM::Tool) do
  description 'Returns a small answer'
  define_method(:name) { 'get_appointment' }
  define_method(:execute) { JSON.generate('success' => true, 'status' => 'scheduled') }
end

# A result that the model has already used is replaced by a short summary built in code: the ids, names, prices and statuses it held
# and the marker that asks the model to call the tool again for details. The tool message stays. All data is synthetic.
RSpec.describe Captain::Runtime::ToolResultExcerpt do
  def tool_message(text, id: 'call_1')
    RubyLLM::Message.new(role: :tool, content: text, tool_call_id: id)
  end

  def answer_with_call(id, name)
    RubyLLM::Message.new(role: :assistant, content: '', tool_calls: { id => RubyLLM::ToolCall.new(id: id, name: name, arguments: {}) })
  end

  def price_link(index, link)
    { 'id' => (index * 4) + link + 1, 'account_id' => 2, 'service_id' => index + 1, 'resource_id' => 100 + link, 'price' => '16500.0',
      'active' => true, 'created_at' => '2026-10-01T09:00:00Z', 'updated_at' => '2026-10-02T09:00:00Z', 'compensation_type' => 'percent',
      'compensation_value' => 0, 'compensation_percent' => 0, 'service_eligibility_status' => 'price_link_unverified' }
  end

  def legacy_service(index)
    { 'id' => index + 1, 'account_id' => 2, 'name' => "Прием врача консультация вариант #{index + 1}", 'base_price' => '16000.0',
      'duration_min' => 30, 'category' => 'Консультации', 'direction' => 'Терапия', 'service_type' => 'visit',
      'description' => 'Первичный прием врача: осмотр, сбор жалоб и анамнеза, назначение обследований и лечения.', 'active' => true,
      'custom_attributes' => { 'medelement_nomenclature_code' => "A#{index}" }, 'prices' => Array.new(4) { |link| price_link(index, link) },
      'created_at' => '2026-10-01T09:00:00Z', 'updated_at' => '2026-10-02T09:00:00Z' }
  end

  # What the agent read before the compact answers: the admin payload of 50 services with four price links each, as pretty JSON.
  def legacy_services_result
    JSON.pretty_generate('filters' => { 'query' => 'консультация', 'include_inactive' => false, 'offset' => 0 }, 'total_count' => 50,
                         'returned_count' => 50, 'has_more' => false, 'next_offset' => nil, 'page_status' => 'returned',
                         'match_status' => 'ambiguous', 'exact_name_matches' => 0, 'services' => Array.new(50) { |index| legacy_service(index) },
                         'instruction' => 'The name differs from the request. Choose the best match from the patient words.')
  end

  def compact_services_result
    JSON.generate('total_count' => 23, 'has_more' => true, 'next_offset' => 10, 'match_status' => 'ambiguous',
                  'services' => Array.new(12) do |index|
                    { 'id' => index + 1, 'name' => "Прием врача консультация вариант #{index + 1}", 'price' => 16_000, 'duration_min' => 30,
                      'doctors' => ["#{100 + index} Врач-специалист Фамилия Имя Отчество", "#{200 + index} Другой Врач Фамилия Имя (18000)",
                                    "#{300 + index} Третий Врач Фамилия Имя", "#{400 + index} Четвертый Врач Фамилия Имя"] }
                  end, 'instruction' => 'The name differs from the request. Choose the best match from the patient words. ' * 3)
  end

  def summary_of(text)
    JSON.parse(described_class.excerpt(text).split("\n", 2).last)
  end

  describe '.excerpt' do
    it 'keeps the ids, names and prices of the first services and the marker, and drops the admin fields', :aggregate_failures do
      text = legacy_services_result
      result = described_class.excerpt(text)
      summary = summary_of(text)
      RSpec.configuration.reporter.message("tool message of 50 services (admin payload): #{text.bytesize} bytes -> #{result.bytesize} bytes")

      expect(result).to start_with("Result shortened after use; call the tool again if you need details.\n")
      expect(summary).to include('total_count' => 50, 'match_status' => 'ambiguous')
      expect(summary['services'].first).to include('id' => 1, 'name' => 'Прием врача консультация вариант 1', 'base_price' => '16000.0')
      expect(summary['services'].first['prices'].first).to include('id' => 1, 'resource_id' => 100, 'price' => '16500.0')
      expect(summary['services'].last).to match(/\A\+\d+ more\z/)
      expect(result).not_to match(/custom_attributes|created_at|updated_at|account_id|compensation|filters|The name differs/)
      expect(result.bytesize).to be <= described_class::BUDGET_BYTES + 100
      expect(result.bytesize).to be < text.bytesize / 40
    end

    it 'keeps the ids and the specialists of the compact service answer' do
      text = compact_services_result
      result = described_class.excerpt(text)
      summary = summary_of(text)
      RSpec.configuration.reporter.message("tool message of 12 compact services: #{text.bytesize} bytes -> #{result.bytesize} bytes")

      expect(text.bytesize).to be > described_class::THRESHOLD_BYTES
      expect(summary).to include('total_count' => 23, 'next_offset' => 10)
      expect(summary['services'].first).to include('id' => 1, 'name' => 'Прием врача консультация вариант 1', 'price' => 16_000,
                                                   'duration_min' => 30)
      expect(summary['services'].first['doctors'].first(2)).to eq(['100 Врач-специалист Фамилия Имя Отчество', '200 Другой Врач Фамилия Имя (18000)'])
      kept = summary['services'].grep(Hash)
      expect(kept.pluck('id')).to eq((1..kept.size).to_a)
      expect(result.bytesize).to be < text.bytesize / 2
    end

    it 'keeps the question, a cut answer and the score of the FAQ matches' do
      answer = 'За восемь часов до исследования не принимать пищу, пить только воду. ' * 12
      text = JSON.generate('result' => 'found', 'matches' => Array.new(5) do |index|
        { 'question' => "Как подготовиться к исследованию номер #{index}?", 'answer' => answer, 'score' => 0.9 }
      end)
      summary = summary_of(text)

      expect(summary['result']).to eq('found')
      expect(summary['matches'].first).to include('question' => 'Как подготовиться к исследованию номер 0?', 'score' => 0.9)
      expect(summary['matches'].first['answer']).to end_with('...').and(satisfy { |value| value.length <= described_class::LONG_TEXT + 3 })
      expect(summary['matches'].size).to be >= 3
    end

    it 'keeps false and 0 and leaves out empty fields' do
      rows = Array.new(300) { |index| { 'id' => index, 'active' => false, 'count' => 0, 'note' => '', 'tags' => [], 'meta' => nil } }
      text = JSON.generate('rows' => rows)

      expect(summary_of(text)['rows'].first).to eq('id' => 0, 'active' => false, 'count' => 0)
    end

    it 'keeps the start of a result that is not JSON' do
      text = "Result: #{'free text ' * 1000}"

      expect(described_class.excerpt(text)).to eq("#{described_class::MARKER}\n#{text.squish.first(described_class::PLAIN_TEXT_CHARS)}...")
    end

    it 'fits any shape into the budget' do
      text = JSON.generate(Array.new(500) { |index| { 'id' => index, 'name' => 'x' * 90, 'status' => 'y' * 90, 'more' => 'z' * 90 } })

      expect(described_class.excerpt(text).bytesize).to be <= described_class::BUDGET_BYTES + described_class::MARKER.bytesize + 1
    end
  end

  describe '.shorten_consumed!' do
    let(:big) { legacy_services_result }
    let(:chat) do
      instance_double(RubyLLM::Chat, messages: [RubyLLM::Message.new(role: :user, content: 'Сколько стоит прием?'),
                                                answer_with_call('call_1', 'search_scheduling_services'), tool_message(big)])
    end

    def tool_contents
      chat.messages.select { |message| message.role == :tool }.map(&:content)
    end

    it 'leaves a result alone until the model has answered it' do
      described_class.shorten_consumed!(chat)

      expect(tool_contents).to eq([big])
    end

    it 'shortens a large result once the model has answered after it, and keeps every tool message' do
      chat.messages << answer_with_call('call_2', 'get_appointment') << tool_message('{"success":true}', id: 'call_2')

      described_class.shorten_consumed!(chat)

      expect(tool_contents.first).to start_with(described_class::MARKER)
      expect(tool_contents.last).to eq('{"success":true}')
      expect(chat.messages.select { |message| message.role == :tool }.map(&:tool_call_id)).to eq(%w[call_1 call_2])
      expect(chat.messages.size).to eq(5)
    end

    it 'does not shorten a small result, and does not shorten a result twice' do
      chat.messages.insert(2, tool_message('{"success":true}', id: 'call_0'))
      chat.messages << RubyLLM::Message.new(role: :assistant, content: 'Ответ')

      described_class.shorten_consumed!(chat)
      once = tool_contents
      described_class.shorten_consumed!(chat)

      expect(once.first).to eq('{"success":true}')
      expect(once.last).to start_with(described_class::MARKER)
      expect(tool_contents).to eq(once)
    end
  end

  describe 'in a chat run' do
    let(:account) { create(:account) }
    let(:model) { 'vendor/excerpt-model' }
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
    let(:requests) { [] }
    let(:headers) { { 'Content-Type' => 'application/json' } }

    def reply(message, finish_reason)
      { id: 'g', model: model, choices: [{ index: 0, message: { role: 'assistant' }.merge(message), finish_reason: finish_reason }],
        usage: { prompt_tokens: 1, completion_tokens: 1 } }.to_json
    end

    def tool_call(id, name)
      reply({ content: nil, tool_calls: [{ id: id, type: 'function', function: { name: name, arguments: '{}' } }] }, 'tool_calls')
    end

    def tool_contents(request)
      request['messages'].select { |message| message['role'] == 'tool' }.to_h { |message| [message['tool_call_id'], message['content']] }
    end

    def build_chat
      Llm::Runtime.build_chat(feature: :captain_agent, account: account, model: model, runtime_preferences: {},
                              options: { context: llm_context, headers: {} }).tap do |chat|
        chat.with_tools(ExcerptSpecBigTool.new, ExcerptSpecSmallTool.new)
        Captain::Runtime::ChatFactory.send(:shorten_consumed_tool_results!, chat)
      end
    end

    before do
      allow(Llm::OpenRouterModelCatalog).to receive(:model_configs).and_return(model => model_config)
      allow(Llm::Config).to receive(:provider_available?) { |provider, **| provider == 'openrouter' }
      allow(Llm::Models).to receive(:model_config).and_call_original
      allow(Llm::Models).to receive(:model_config).with(model, account: account).and_return(model_config)
      stub_request(:post, 'https://openrouter.example/api/v1/chat/completions')
        .with { |http_request| requests << JSON.parse(http_request.body) }
        .to_return(status: 200, headers: headers, body: tool_call('call_1', 'search_scheduling_services')).then
        .to_return(status: 200, headers: headers, body: tool_call('call_2', 'get_appointment')).then
        .to_return(status: 200, headers: headers, body: reply({ content: 'Прием стоит 1000 тенге.' }, 'stop'))
    end

    it 'sends the full result to the next step and the summary from the step after it, never dropping a tool message', :aggregate_failures do
      expect(build_chat.ask('Сколько стоит прием?').content).to eq('Прием стоит 1000 тенге.')

      expect(requests.size).to eq(3)
      full = ExcerptSpecBigTool.new.execute
      expect(tool_contents(requests[1])).to eq('call_1' => full)
      third = tool_contents(requests[2])
      expect(third.keys).to eq(%w[call_1 call_2])
      expect(third['call_1']).to start_with(described_class::MARKER)
      expect(third['call_1']).to include('"id":1', 'Услуга номер 1 с длинным названием', '"price":1000')
      expect(third['call_1'].bytesize).to be < full.bytesize / 2
      expect(third['call_2']).to eq(ExcerptSpecSmallTool.new.execute)
      RSpec.configuration.reporter.message("step 3 of a run, large tool message: #{full.bytesize} bytes -> #{third['call_1'].bytesize} bytes")
    end

    it 'shows a callback that records the answer of the model the full result it read, not the summary' do
      chat = build_chat
      seen = []
      chat.after_message do |message|
        seen << chat.messages.select { |item| item.role == :tool }.map { |item| item.content.bytesize } if message.role == :assistant
      end

      chat.ask('Сколько стоит прием?')

      expect(seen[1].first).to be > described_class::THRESHOLD_BYTES
      expect(seen[2].first).to be <= described_class::BUDGET_BYTES + 100
    end
  end
end
