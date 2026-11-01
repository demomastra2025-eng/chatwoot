# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Integrations::KaspiPay::AppVersionResolver do
  before do
    Redis::Alfred.delete(described_class::REDIS_CACHE_KEY)
    Redis::Alfred.delete(described_class::REDIS_BUILD_CACHE_KEY)
  end

  after do
    Redis::Alfred.delete(described_class::REDIS_CACHE_KEY)
    Redis::Alfred.delete(described_class::REDIS_BUILD_CACHE_KEY)
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

    it 'preserves an already-cached newer version instead of negative-caching when force_refresh times out' do
      Redis::Alfred.setex(described_class::REDIS_CACHE_KEY, '26.1130', 3600)
      stub_request(:get, described_class::ITUNES_LOOKUP_URL).to_timeout

      expect(described_class.resolve(force_refresh: true, allow_network: true)).to eq('26.1130')
      expect(Redis::Alfred.get(described_class::REDIS_CACHE_KEY)).to eq('26.1130')
      expect(described_class.sanitize_saved_version('26.1029')).to be_nil
      expect(described_class.sanitize_saved_version('26.1130')).to eq('26.1130')
    end
  end

  describe '.resolve_build and .sanitize_saved_build' do
    it 'defaults to FALLBACK_BUILD, accepts date-style builds, and rejects stale or malformed build overrides' do
      expect(described_class.resolve_build).to eq('1116')
      expect(described_class.sanitize_saved_build('1115')).to be_nil
      expect(described_class.sanitize_saved_build('1116; evil=1')).to be_nil
      expect(described_class.sanitize_saved_build(' 1125 ')).to eq('1125')
      expect(described_class.sanitize_saved_build('20261115')).to eq('20261115')
    end

    it 'caches resolved builds monotonically in Redis' do
      described_class.cache_resolved_build!('1130')
      expect(described_class.resolve_build).to eq('1130')
      expect(described_class.sanitize_saved_build('1125')).to be_nil
      expect(described_class.cache_resolved_build!('1120')).to eq('1130')
    end
  end

  describe '.discover_working_build!' do
    it 'finds the exact minimum accepted Kaspi Pay build via exponential bracket and binary search' do
      probes = []
      discovered = described_class.discover_working_build!(current_build: '1116', version: '26.1029') do |candidate|
        probes << candidate.to_i
        candidate.to_i >= 1124
      end

      expect(discovered).to eq('1124')
      expect(described_class.resolve_build).to eq('1124')
      expect(probes.length).to be <= 7
    end

    it 'returns nil when all bracket probes still fail with OldVersionToUpdate' do
      discovered = described_class.discover_working_build!(current_build: '1116', version: '26.1029') { false }

      expect(discovered).to be_nil
      expect(described_class.resolve_build).to eq(described_class::FALLBACK_BUILD)
    end

    it 'propagates network errors from default entrance probes instead of treating them as outdated builds' do
      stub_request(:post, 'https://entrance-pay.kaspi.kz/api/v1/entrance/step').to_timeout

      expect do
        described_class.discover_working_build!(current_build: '1116', version: '26.1029')
      end.to raise_error(Integrations::KaspiPay::ApiClient::ApiError) { |err| expect(err.code).to eq('NetworkError') }
    end
  end
end
