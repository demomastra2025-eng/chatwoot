# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Evals::Scenario::ClientCache do
  it 'caches responses by canonical request digest' do
    store = ActiveSupport::Cache::MemoryStore.new
    cache = described_class.new(cache_key: 'case-1', store: store, namespace: 'judge')
    calls = 0

    first = cache.fetch({ b: 2, a: 1 }) do
      calls += 1
      { verdict: 'success' }
    end
    second = cache.fetch({ a: 1, b: 2 }) do
      calls += 1
      { verdict: 'failure' }
    end

    expect(first).to eq(verdict: 'success')
    expect(second).to eq(verdict: 'success')
    expect(calls).to eq(1)
  end

  it 'raises a cache miss in read-only replay mode without a cached response' do
    cache = described_class.new(
      cache_key: 'case-1',
      store: ActiveSupport::Cache::MemoryStore.new,
      mode: :read_only
    )

    expect { cache.fetch({ input: 'hello' }) }.to raise_error(described_class::CacheMiss)
  end

  it 'is disabled unless both store and cache key are present' do
    cache = described_class.new(cache_key: nil, store: ActiveSupport::Cache::MemoryStore.new)
    calls = 0

    expect(cache.fetch({ input: 'hello' }) do
      calls += 1
      'fresh'
    end).to eq('fresh')
    expect(cache).not_to be_enabled
    expect(calls).to eq(1)
  end
end
