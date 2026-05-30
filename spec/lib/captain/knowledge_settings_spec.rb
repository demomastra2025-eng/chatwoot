# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::KnowledgeSettings do
  describe '.normalize_chunk_size' do
    it 'uses the default for blank or invalid values' do
      expect(described_class.normalize_chunk_size(nil)).to eq(described_class::DEFAULT_CHUNK_SIZE)
      expect(described_class.normalize_chunk_size('invalid')).to eq(described_class::DEFAULT_CHUNK_SIZE)
    end

    it 'clamps values to the supported range' do
      expect(described_class.normalize_chunk_size(1)).to eq(described_class::MIN_CHUNK_SIZE)
      expect(described_class.normalize_chunk_size(100_000)).to eq(described_class::MAX_CHUNK_SIZE)
    end
  end

  describe '.estimated_tokens_for_chunk_size' do
    it 'estimates tokens from the normalized character chunk size' do
      expect(described_class.estimated_tokens_for_chunk_size(20_000)).to eq(5000)
    end
  end

  describe '.chunk_size_for_context_length' do
    it 'converts model token context to a rounded character chunk size' do
      expect(described_class.chunk_size_for_context_length(8192)).to eq(32_000)
    end

    it 'clamps model-derived chunk sizes to the supported range' do
      expect(described_class.chunk_size_for_context_length(256)).to eq(described_class::MIN_CHUNK_SIZE)
      expect(described_class.chunk_size_for_context_length(100_000)).to eq(described_class::MAX_CHUNK_SIZE)
    end
  end

  describe '.chunk_size_options_for_context_lengths' do
    it 'builds sorted chunk options from model contexts and included runtime values' do
      expect(described_class.chunk_size_options_for_context_lengths([8192, 16_384], include_values: [12_000]))
        .to eq([12_000, 32_000, 50_000])
    end
  end
end
