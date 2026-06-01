# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain web access tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:firecrawl) { instance_double(Captain::Tools::FirecrawlService) }

  before do
    allow(Captain::Tools::FirecrawlService).to receive(:configured?).and_return(true)
    allow(Captain::Tools::FirecrawlService).to receive(:new).and_return(firecrawl)
  end

  describe Captain::Tools::Copilot::WebSearchService do
    it 'searches through Firecrawl when web search is enabled' do
      account.update!(captain_runtime: { 'web_search_enabled' => true, 'web_search_max_results' => 3 })
      allow(firecrawl).to receive(:search).and_return(
        double(parsed_response: {
                 'success' => true,
                 'data' => {
                   'web' => [
                     { 'title' => 'Firecrawl Search', 'url' => 'https://docs.firecrawl.dev/search', 'description' => 'Search docs' }
                   ]
                 }
               })
      )

      payload = JSON.parse(described_class.new(assistant).execute(query: 'firecrawl search'))

      expect(payload.dig('data', 'action')).to eq('web_search')
      expect(payload.dig('data', 'provider')).to eq('firecrawl')
      expect(payload.dig('data', 'results', 0, 'url')).to eq('https://docs.firecrawl.dev/search')
      expect(firecrawl).to have_received(:search).with(
        'firecrawl search',
        hash_including(limit: 3, sources: ['web'], scrape_results: false)
      )
    end

    it 'is not available until enabled in Captain runtime settings' do
      expect(described_class.new(assistant).execute(query: 'firecrawl')).to start_with('ERROR:')
    end
  end

  describe Captain::Tools::Copilot::WebScrapeUrlService do
    it 'reads a public URL through Firecrawl when page reading is enabled' do
      long_body = 'A' * 1100
      account.update!(captain_runtime: { 'web_scrape_enabled' => true, 'web_scrape_max_chars' => 1000 })
      allow(firecrawl).to receive(:scrape).and_return(
        double(parsed_response: {
                 'success' => true,
                 'data' => {
                   'markdown' => long_body,
                   'metadata' => { 'title' => 'Docs', 'sourceURL' => 'https://docs.firecrawl.dev/scrape' }
                 }
               })
      )

      payload = JSON.parse(described_class.new(assistant).execute(url: 'https://docs.firecrawl.dev/scrape'))

      expect(payload.dig('data', 'action')).to eq('web_scrape_url')
      expect(payload.dig('data', 'title')).to eq('Docs')
      expect(payload.dig('data', 'markdown')).to eq('A' * 1000)
      expect(payload.dig('data', 'truncated')).to be(true)
    end

    it 'rejects local URLs' do
      account.update!(captain_runtime: { 'web_scrape_enabled' => true })

      expect(described_class.new(assistant).execute(url: 'http://localhost:3000')).to include('ERROR:')
    end
  end

  describe Captain::ToolCatalog do
    it 'exposes web access tools only when Firecrawl and runtime toggles are enabled' do
      expect(described_class.available_tool_ids_for(assistant, Captain::ToolAccess::SCOPE_AGENT))
        .not_to include('web_search', 'web_scrape_url')

      account.update!(captain_runtime: { 'web_search_enabled' => true, 'web_scrape_enabled' => true })

      expect(described_class.available_tool_ids_for(assistant, Captain::ToolAccess::SCOPE_AGENT))
        .to include('web_search', 'web_scrape_url')
      expect(described_class.available_tool_ids_for(assistant, Captain::ToolAccess::SCOPE_ASSISTANT))
        .to include('web_search', 'web_scrape_url')
    end
  end
end
