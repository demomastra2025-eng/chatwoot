# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::AppVersionResolver do
  before do
    Redis::Alfred.delete(described_class::REDIS_CACHE_KEY)
  end

  after do
    Redis::Alfred.delete(described_class::REDIS_CACHE_KEY)
  end

  describe '.resolve' do
    it 'fetches the current Kazakhstan App Store version and caches it in Redis' do
      lookup_stub = stub_request(:get, described_class::ITUNES_LOOKUP_URL)
                    .to_return(
                      status: 200,
                      headers: { 'Content-Type' => 'application/json' },
                      body: { resultCount: 1, results: [{ bundleId: 'kz.kaspi.business', version: '26.1120' }] }.to_json
                    )

      expect(described_class.resolve(allow_network: true)).to eq('26.1120')
      expect(described_class.resolve(allow_network: true)).to eq('26.1120')
      expect(lookup_stub).to have_been_requested.once
    end

    it 'bypasses stale Redis cache when force_refresh is true' do
      Redis::Alfred.setex(described_class::REDIS_CACHE_KEY, '26.1029', 3600)
      stub_request(:get, described_class::ITUNES_LOOKUP_URL)
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { resultCount: 1, results: [{ version: '26.1215' }] }.to_json
        )

      expect(described_class.resolve(force_refresh: true, allow_network: true)).to eq('26.1215')
      expect(Redis::Alfred.get(described_class::REDIS_CACHE_KEY)).to eq('26.1215')
    end

    it 'never downgrades below FALLBACK_VERSION even if cache or App Store returns an older version' do
      Redis::Alfred.setex(described_class::REDIS_CACHE_KEY, '26.0921', 3600)
      stub_request(:get, described_class::ITUNES_LOOKUP_URL)
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { resultCount: 1, results: [{ version: '26.0921' }] }.to_json
        )

      expect(described_class.resolve(allow_network: true)).to eq(described_class::FALLBACK_VERSION)
      expect(Redis::Alfred.get(described_class::REDIS_CACHE_KEY)).to eq(described_class::NEGATIVE_SENTINEL)
    end

    it 'falls back safely and writes negative cache when App Store times out or returns non-200' do
      lookup_stub = stub_request(:get, described_class::ITUNES_LOOKUP_URL).to_timeout

      expect(described_class.resolve(allow_network: true)).to eq(described_class::FALLBACK_VERSION)
      expect(described_class.resolve(allow_network: true)).to eq(described_class::FALLBACK_VERSION)
      expect(lookup_stub).to have_been_requested.once
    end
  end
end
