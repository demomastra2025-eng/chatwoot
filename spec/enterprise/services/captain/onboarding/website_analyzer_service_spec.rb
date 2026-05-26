require 'rails_helper'

RSpec.describe Captain::Onboarding::WebsiteAnalyzerService do
  let(:website_url) { 'https://example.com' }
  let(:account) { create(:account) }
  let(:service) { described_class.new(website_url, account: account) }
  let(:mock_crawler) { instance_double(Captain::Tools::SimplePageCrawlService) }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:business_info) do
    {
      'business_name' => 'Example Corp',
      'suggested_assistant_name' => 'Alex from Example Corp',
      'description' => 'You specialize in helping customers with business solutions and support'
    }
  end
  let(:mock_response) do
    instance_double(RubyLLM::Message, content: business_info)
  end

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
    account.update!(captain_models: { 'assistant' => 'gpt-5.2' })
    allow(Captain::Tools::SimplePageCrawlService).to receive(:new).and_return(mock_crawler)
    allow(Llm::ChatClient).to receive(:build).and_return(mock_chat)
    allow(Llm::ChatClient).to receive(:ask).and_return(mock_response)
    allow(Llm::CapabilityPolicy).to receive(:ensure_chat_features_supported!)
    allow(Llm::StructuredOutputPolicy).to receive(:bind!).and_return(mock_chat)
    allow(mock_chat).to receive(:with_params).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
  end

  describe '#analyze' do
    context 'when website content is available and LLM call is successful' do
      before do
        allow(mock_crawler).to receive(:body_text_content).and_return('Welcome to Example Corp')
        allow(mock_crawler).to receive(:page_title).and_return('Example Corp - Home')
        allow(mock_crawler).to receive(:meta_description).and_return('Leading provider of business solutions')
        allow(mock_crawler).to receive(:favicon_url).and_return('https://example.com/favicon.ico')
      end

      it 'returns successful analysis with extracted business info' do
        result = service.analyze

        expect(result[:success]).to be true
        expect(result[:data]).to include(
          business_name: 'Example Corp',
          suggested_assistant_name: 'Alex from Example Corp',
          description: 'You specialize in helping customers with business solutions and support',
          website_url: website_url,
          favicon_url: 'https://example.com/favicon.ico'
        )
      end

      it 'builds chat with low temperature, resolved account model, and account context' do
        expect(Llm::ChatClient).to receive(:build).with(
          hash_including(account: account, model: 'gpt-5.2', temperature: 0.1)
        ).and_return(mock_chat)

        service.analyze
      end

      it 'parses legacy JSON string responses' do
        legacy_response = instance_double(RubyLLM::Message, content: business_info.to_json)
        allow(Llm::ChatClient).to receive(:ask).and_return(legacy_response)

        result = service.analyze

        expect(result[:success]).to be true
        expect(result[:data]).to include(
          business_name: 'Example Corp',
          suggested_assistant_name: 'Alex from Example Corp',
          description: 'You specialize in helping customers with business solutions and support'
        )
      end

      it 'supports legacy construction without account context' do
        legacy_service = described_class.new(website_url)
        expect(Llm::ChatClient).to receive(:build).with(hash_excluding(:account)).and_return(mock_chat)
        expect(Llm::ChatClient).to receive(:ask).with(
          mock_chat,
          kind_of(String),
          hash_excluding(:account)
        ).and_return(mock_response)

        result = legacy_service.analyze

        expect(result[:success]).to be true
      end

      it 'keeps website content out of the system prompt and sends it as user content once' do
        expect(mock_chat).to receive(:with_instructions)
          .with(satisfy { |prompt| prompt.exclude?('Welcome to Example Corp') })
          .and_return(mock_chat)
        expect(Llm::ChatClient).to receive(:ask).with(
          mock_chat,
          'Title: Example Corp - Home Description: Leading provider of business solutions Welcome to Example Corp',
          hash_including(account: account, model: 'gpt-5.2')
        ).and_return(mock_response)

        service.analyze
      end
    end

    context 'when website content fetch raises an error' do
      before do
        allow(mock_crawler).to receive(:body_text_content).and_raise(StandardError, 'Network error')
      end

      it 'returns error response' do
        result = service.analyze

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to fetch website content')
      end
    end

    context 'when website content is empty' do
      before do
        allow(mock_crawler).to receive(:body_text_content).and_return('')
        allow(mock_crawler).to receive(:page_title).and_return('')
        allow(mock_crawler).to receive(:meta_description).and_return('')
      end

      it 'returns error for unavailable content' do
        result = service.analyze

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to fetch website content')
      end
    end

    context 'when LLM call fails' do
      before do
        allow(mock_crawler).to receive(:body_text_content).and_return('Welcome to Example Corp')
        allow(mock_crawler).to receive(:page_title).and_return('Example Corp - Home')
        allow(mock_crawler).to receive(:meta_description).and_return('Leading provider of business solutions')
        allow(mock_crawler).to receive(:favicon_url).and_return('https://example.com/favicon.ico')
        allow(Llm::ChatClient).to receive(:ask).and_raise(StandardError, 'API error')
      end

      it 'returns error response with message' do
        result = service.analyze

        expect(result[:success]).to be false
        expect(result[:error]).to eq('API error')
      end
    end

    context 'when LLM returns invalid JSON' do
      let(:invalid_response) { instance_double(RubyLLM::Message, content: 'not valid json') }

      before do
        allow(mock_crawler).to receive(:body_text_content).and_return('Welcome to Example Corp')
        allow(mock_crawler).to receive(:page_title).and_return('Example Corp - Home')
        allow(mock_crawler).to receive(:meta_description).and_return('Leading provider of business solutions')
        allow(mock_crawler).to receive(:favicon_url).and_return('https://example.com/favicon.ico')
        allow(Llm::ChatClient).to receive(:ask).and_return(invalid_response)
      end

      it 'returns error for parsing failure' do
        result = service.analyze

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to parse business information from website')
      end
    end

    context 'when URL normalization is needed' do
      let(:website_url) { 'example.com' }

      before do
        allow(mock_crawler).to receive(:body_text_content).and_return('Welcome')
        allow(mock_crawler).to receive(:page_title).and_return('Example')
        allow(mock_crawler).to receive(:meta_description).and_return('Description')
        allow(mock_crawler).to receive(:favicon_url).and_return(nil)
      end

      it 'normalizes URL by adding https prefix' do
        result = service.analyze

        expect(result[:data][:website_url]).to eq('https://example.com')
      end
    end
  end
end
