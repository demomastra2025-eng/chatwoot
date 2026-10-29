# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OutboundIinRedactor do
  describe '.redact_payload' do
    let(:sample_payload) do
      {
        model: 'openai/gpt-5.4-mini',
        id: '940720300129',
        messages: [
          { role: 'system', content: 'Карточка пациента: 940720300129' },
          {
            role: 'user',
            content: [
              { type: 'text', text: 'Мой ИИН 900101300123 и телефон +7 701 123 45 67' },
              { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,940720300129AAAA' } }
            ]
          },
          {
            role: 'tool',
            tool_call_id: 'call_940720300129',
            content: '{"contact":{"name":"Асет","iin":"900101300123","note":"940720-300129"}}'
          }
        ],
        extra: { 'iin' => '900101300123', 'thought_signature' => '940720300129' }
      }
    end

    it 'deep-redacts personal and labeled IINs without mutating the input hash' do
      snapshot = Marshal.load(Marshal.dump(sample_payload))
      redacted = described_class.redact_payload(sample_payload)

      expect(sample_payload).to eq(snapshot)
      expect(redacted[:messages][0][:content]).to eq('Карточка пациента: [ИИН СКРЫТ]')
      expect(redacted[:messages][1][:content][0][:text]).to eq('Мой ИИН [ИИН СКРЫТ] и телефон +7 701 123 45 67')
      expect(redacted[:messages][2][:content]).to eq('{"contact":{"name":"Асет","iin":"[ИИН СКРЫТ]","note":"[ИИН СКРЫТ]"}}')
      expect(redacted[:extra]['iin']).to eq('[ИИН СКРЫТ]')
    end

    it 'preserves skipped metadata keys and data URIs untouched' do
      redacted = described_class.redact_payload(sample_payload)

      expect(redacted[:id]).to eq('940720300129')
      expect(redacted[:messages][1][:content][1][:image_url][:url]).to eq('data:image/jpeg;base64,940720300129AAAA')
      expect(redacted[:messages][2][:tool_call_id]).to eq('call_940720300129')
      expect(redacted[:extra]['thought_signature']).to eq('940720300129')
    end

    it 'redacts nested data/provider/file hashes and client_identifier keys while preserving base64 media data' do
      payload = {
        'data' => { 'patient' => { 'iin' => '900101300123', 'client_identifier' => '900101300123', 'note' => '940720300129' } },
        'provider' => { 'prompt' => 'Пациент 940720300129' },
        'file' => { 'filename' => 'card_940720300129.pdf' },
        'inline_media' => { 'type' => 'base64', 'media_type' => 'image/jpeg', 'data' => '940720300129AAAA' }
      }

      redacted = described_class.redact_payload(payload)

      expect(redacted['data']['patient']).to eq('iin' => '[ИИН СКРЫТ]', 'client_identifier' => '[ИИН СКРЫТ]', 'note' => '[ИИН СКРЫТ]')
      expect(redacted['provider']['prompt']).to eq('Пациент [ИИН СКРЫТ]')
      expect(redacted['file']['filename']).to eq('card_[ИИН СКРЫТ].pdf')
      expect(redacted['inline_media']['data']).to eq('940720300129AAAA')
    end
  end

  describe 'outbound LLM HTTP gateways' do
    it 'redacts IINs in RubyLLM::Connection#post before the payload leaves OneLink' do
      stub = stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions').with do |request|
        body = JSON.parse(request.body)
        expect(request.body).not_to include('940720300129', '900101300123')
        expect(body.dig('messages', 0, 'content')).to eq('Пациент [ИИН СКРЫТ], ИИН: [ИИН СКРЫТ]')
        true
      end.to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: {
          id: 'gen-1',
          model: 'openai/gpt-5.4-mini',
          choices: [{ index: 0, message: { role: 'assistant', content: 'Готово' }, finish_reason: 'stop' }],
          usage: { prompt_tokens: 10, completion_tokens: 2, total_tokens: 12 }
        }.to_json
      )

      context = RubyLLM.context do |config|
        config.openrouter_api_key = 'synthetic-key'
        config.openrouter_api_base = 'https://openrouter.ai/api/v1'
      end
      provider = RubyLLM::Providers::OpenRouter.new(context.config)
      connection = RubyLLM::Connection.new(provider, context.config)

      response = connection.post('chat/completions', {
                                   model: 'openai/gpt-5.4-mini',
                                   messages: [{ role: 'user', content: 'Пациент 940720300129, ИИН: 900101300123' }]
                                 })

      expect(response.status).to eq(200)
      expect(stub).to have_been_requested.once
    end

    it 'redacts IINs in Llm::OpenRouterDecisionClient outbound state and questions' do
      criteria = { 'ok' => 'Valid', 'other' => 'Other' }
      stub = stub_request(:post, 'https://openrouter.ai/api/alpha/decisions').with do |request|
        expect(request.body).not_to include('940720300129', '900101300123')
        parsed = JSON.parse(request.body)
        expect(parsed.dig('state', 'messages', 0)).to eq('Мой ИИН [ИИН СКРЫТ]')
        expect(parsed.dig('questions', 'reason', 'instructions')).to eq('Проверь [ИИН СКРЫТ]')
        expect(parsed.dig('questions', 'reason', 'criteria')).to eq(criteria)
        true
      end.to_return(
        status: 200,
        body: {
          id: 'gen-dec',
          model: 'microsoft/microsoft-decision-1',
          answers: { reason: { choice: 'ok', confidence: 0.99 } },
          usage: { input_tokens: 10, output_tokens: 1, cost: 0.0 }
        }.to_json
      )

      result = Llm::OpenRouterDecisionClient.choose(
        state: { messages: ['Мой ИИН 900101300123'] },
        criteria: criteria,
        instructions: 'Проверь 940720300129',
        model: 'microsoft/microsoft-decision-1',
        api_key: 'synthetic-key'
      )

      expect(result.choice).to eq('ok')
      expect(stub).to have_been_requested.once
    end

    it 'redacts IINs in Llm::OpenRouterEmbeddingClient outbound input' do
      stub = stub_request(:post, 'https://openrouter.ai/api/v1/embeddings').with do |request|
        expect(request.body).not_to include('940720300129')
        expect(JSON.parse(request.body)['input']).to eq(['Запись пациента [ИИН СКРЫТ] на УЗИ'])
        true
      end.to_return(
        status: 200,
        body: { data: [{ index: 0, embedding: [0.1, 0.2] }], usage: { prompt_tokens: 5 } }.to_json
      )

      result = Llm::OpenRouterEmbeddingClient.embed(
        ['Запись пациента 940720300129 на УЗИ'],
        model: 'qwen/qwen3-embedding-8b',
        api_key: 'synthetic-key'
      )

      expect(result.vectors).to eq([[0.1, 0.2]])
      expect(stub).to have_been_requested.once
    end

    it 'redacts IINs in Llm::OpenRouterRerankClient outbound query and documents' do
      stub = stub_request(:post, 'https://openrouter.ai/api/v1/rerank').with do |request|
        expect(request.body).not_to include('940720300129', '900101300123')
        parsed = JSON.parse(request.body)
        expect(parsed['query']).to eq('Пациент [ИИН СКРЫТ]')
        expect(parsed['documents']).to eq(['ИИН: [ИИН СКРЫТ]'])
        true
      end.to_return(
        status: 200,
        body: { results: [{ index: 0, relevance_score: 0.91 }], usage: {} }.to_json
      )

      result = Llm::OpenRouterRerankClient.rerank(
        query: 'Пациент 940720300129',
        documents: ['ИИН: 900101300123'],
        model: 'cohere/rerank-v3.5',
        api_key: 'synthetic-key'
      )

      expect(result.results.first.index).to eq(0)
      expect(stub).to have_been_requested.once
    end

    it 'redacts IINs in Llm::OpenRouterTranscriptionClient provider prompt while leaving base64 audio data intact' do
      Tempfile.create(['sample', '.wav']) do |audio|
        audio.binmode
        audio.write('RIFF0000WAVE')
        audio.flush

        expected_b64 = Base64.strict_encode64('RIFF0000WAVE')
        stub = stub_request(:post, 'https://openrouter.ai/api/v1/audio/transcriptions').with do |request|
          expect(request.body).not_to include('940720300129')
          parsed = JSON.parse(request.body)
          expect(parsed.dig('input_audio', 'data')).to eq(expected_b64)
          expect(parsed.dig('provider', 'options', 'openai', 'prompt')).to eq('Контекст: [ИИН СКРЫТ]')
          true
        end.to_return(status: 200, body: { text: 'Здравствуйте', usage: { seconds: 2 } }.to_json)

        transcription = Llm::OpenRouterTranscriptionClient.transcribe(
          audio.path,
          model: 'openai/gpt-4o-transcribe',
          api_key: 'synthetic-key',
          prompt: 'Контекст: 940720300129'
        )

        expect(transcription.text).to eq('Здравствуйте')
        expect(stub).to have_been_requested.once
      end
    end
  end

  describe 'LLM formatters and Captain::ContextFields' do
    it 'strips iin/medelement_iin attributes and redacts embedded IINs across LLM formatters' do
      account = create(:account)
      account.enable_features!('scheduling')
      create(:custom_attribute_definition, account: account, attribute_key: 'iin', attribute_display_name: 'ИИН', attribute_model: :contact_attribute)
      create(
        :custom_attribute_definition,
        account: account,
        attribute_key: 'clinic_branch',
        attribute_display_name: 'Филиал',
        attribute_model: :contact_attribute
      )

      contact = create(
        :contact,
        account: account,
        name: 'Айгуль',
        identifier: '940720300129',
        custom_attributes: { 'iin' => '940720300129', 'medelement_iin' => '940720300129', 'clinic_branch' => 'Алматы' }
      )
      create(:note, account: account, contact: contact, content: 'ИИН пациента 940720300129')

      contact_text = LlmFormatter::ContactLlmFormatter.new(contact).format
      expect(contact_text).not_to include('940720300129')
      expect(contact_text).to include('Филиал: Алматы', '[ИИН СКРЫТ]')

      conversation = create(:conversation, account: account, contact: contact)
      create(:message, account: account, inbox: conversation.inbox, conversation: conversation, sender: contact,
                       message_type: :incoming, content: 'Здравствуйте, мой ИИН 900101300123')

      conv_text = LlmFormatter::ConversationLlmFormatter.new(conversation).format(include_contact_details: true)
      expect(conv_text).not_to include('940720300129', '900101300123')
      expect(conv_text).to include('[ИИН СКРЫТ]')

      doctor = create(:scheduling_resource, account: account, name: 'Доктор А', timezone: 'Asia/Almaty')
      appointment = create(
        :scheduling_appointment,
        account: account,
        contact: contact,
        resource: doctor,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 30.minutes,
        client_identifier: '940720300129',
        custom_attributes: { 'iin' => '940720300129', 'comment' => 'Карта 940720300129' }
      )

      appt_text = LlmFormatter::Scheduling::AppointmentLlmFormatter.new(appointment).format
      expect(appt_text).not_to include('940720300129')
      expect(appt_text).to include('[ИИН СКРЫТ]')
    end

    it 'hides IINs in both Captain::ContextFields prompt mode and outgoing customer runtime text while preserving non-IIN fields' do
      account = create(:account)
      account.enable_features!('scheduling')
      create(:custom_attribute_definition, account: account, attribute_key: 'iin', attribute_display_name: 'ИИН', attribute_model: :contact_attribute)
      assistant = create(
        :captain_assistant,
        account: account,
        description: 'ID: [$ID](field://contact.identifier), IIN: [$IIN](field://contact.custom_attributes.iin)'
      )
      contact = create(:contact, account: account, name: 'Айгуль', identifier: '940720300129', custom_attributes: { 'iin' => '900101300123' })
      conversation = create(:conversation, account: account, contact: contact)

      runtime_state = Captain::ContextFields.runtime_state_for(account: account, conversation: conversation, assistant: assistant)
      prompt_rendered = assistant.agent_instructions(Captain::Runtime::RunContext.new({ state: runtime_state }))
      customer_rendered = assistant.render_runtime_text(
        'ID: [$ID](field://contact.identifier), IIN: [$IIN](field://contact.custom_attributes.iin)',
        conversation: conversation
      )

      expect(prompt_rendered).to include('ID: not specified, IIN: not specified')
      expect(prompt_rendered).not_to include('940720300129')
      expect(customer_rendered).to eq('ID: [ИИН СКРЫТ], IIN: [ИИН СКРЫТ]')

      crm_contact = create(:contact, account: account, name: 'Айгуль', identifier: 'CRM-004219')
      crm_conversation = create(:conversation, account: account, contact: crm_contact)
      non_iin_rendered = assistant.render_runtime_text(
        'ID: [$ID](field://contact.identifier), Имя: [$Name](field://contact.name)',
        conversation: crm_conversation
      )
      expect(non_iin_rendered).to eq('ID: CRM-004219, Имя: Айгуль')
    end

    it 'hides IIN parameters and descriptions from Telephony::AiVoice::ToolDispatchService catalog and execution args' do
      account = create(:account)
      account.enable_features!('scheduling')
      assistant = create(:captain_assistant, account: account)
      allow(assistant).to receive(:voice_runtime_agent_tools).and_return(
        [{ id: 'search_appointments' }, { id: 'update_my_contact' }, { id: 'update_contact' }]
      )

      catalog = Telephony::AiVoice::ToolDispatchService.captain_tool_catalog(assistant)
      by_name = catalog.index_by { |entry| entry['name'] }

      expect(by_name.dig('search_appointments', 'description')).not_to match(/\bIIN\b/i)
      expect(by_name.dig('search_appointments', 'parameters', 'properties')).not_to have_key('client_identifier')
      expect(by_name.dig('update_my_contact', 'parameters', 'properties')).not_to have_key('iin')
      expect(by_name.dig('update_contact', 'parameters', 'properties')).not_to have_key('identifier')

      override = Telephony::AiVoice::ToolDispatchService.agent_tool_text_override(id: 'update_my_contact')
      expect(override.hidden_params).to include('iin')
    end
  end
end
