require 'rails_helper'

RSpec.describe Captain::Llm::ArticleSearchTermsService do
  let(:account) { create(:account) }
  let(:portal) { create(:portal, account: account) }
  let(:author) { create(:user, account_ids: [account.id]) }
  let(:article) { create(:article, account: account, portal: portal, author: author, title: 'Billing FAQ', description: 'How billing works', content: 'Detailed billing article') }
  let(:service) { described_class.new(article) }
  let(:mock_chat) { instance_double(RubyLLM::Chat) }
  let(:mock_response) do
    instance_double(RubyLLM::Message, content: { search_terms: ['billing', 'invoice status', 'billing'] })
  end

  before do
    upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', 'test-key')
    upsert_installation_config('CAPTAIN_OPEN_AI_ENDPOINT', '')
    allow(RubyLLM).to receive(:chat).and_return(mock_chat)
    allow(mock_chat).to receive(:with_temperature).and_return(mock_chat)
    allow(mock_chat).to receive(:with_schema).and_return(mock_chat)
    allow(mock_chat).to receive(:with_instructions).and_return(mock_chat)
    allow(mock_chat).to receive(:ask).and_return(mock_response)
  end

  describe '#generate' do
    it 'uses a low temperature suitable for deterministic indexing' do
      expect(service.temperature).to eq(0.2)
    end

    it 'returns normalized unique search terms from the schema response' do
      expect(service.generate).to eq(['billing', 'invoice status'])
    end

    it 'attaches the search term schema to the chat' do
      expect(mock_chat).to receive(:with_schema).with(Captain::Llm::Schemas::SearchTermCollection).and_return(mock_chat)
      service.generate
    end

    it 'works with a blank endpoint installation config by using shared LLM config' do
      expect(service.generate).to eq(['billing', 'invoice status'])
      expect(Llm::Config.api_base('openai')).to eq('https://api.openai.com/v1')
    end

    context 'when the provider api key is missing' do
      before do
        upsert_installation_config('CAPTAIN_OPEN_AI_API_KEY', '')
        allow(Rails.logger).to receive(:warn)
      end

      it 'returns nil and skips the request' do
        expect(Rails.logger).to receive(:warn).with(/Skipping article search term generation/)
        expect(mock_chat).not_to receive(:ask)
        expect(service.generate).to be_nil
      end
    end

    context 'when the LLM request fails' do
      before do
        allow(mock_chat).to receive(:ask).and_raise(RubyLLM::Error.new(nil, 'API Error'))
        allow(Rails.logger).to receive(:error)
      end

      it 'returns nil and logs the error' do
        expect(Rails.logger).to receive(:error).with(/Article search terms LLM API Error/)
        expect(service.generate).to be_nil
      end
    end
  end
end
