# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ApiClient do
  describe '.configure' do
    it 'delegates to RubyLLM.configure' do
      yielded_config = Object.new

      expect(RubyLLM).to receive(:configure).and_yield(yielded_config)

      yielded = nil
      described_class.configure { |config| yielded = config }

      expect(yielded).to eq(yielded_config)
    end
  end

  describe '.context' do
    it 'delegates to RubyLLM.context' do
      context = double('context')
      yielded_config = Object.new

      expect(RubyLLM).to receive(:context).and_yield(yielded_config).and_return(context)

      yielded = nil
      result = described_class.context { |config| yielded = config }

      expect(result).to eq(context)
      expect(yielded).to eq(yielded_config)
    end
  end

  describe '.embed' do
    it 'delegates to RubyLLM.embed' do
      expect(RubyLLM).to receive(:embed).with('hello', model: 'text-embedding-3-small', dimensions: 1536)

      described_class.embed('hello', model: 'text-embedding-3-small', dimensions: 1536)
    end
  end

  describe '.moderate' do
    it 'delegates to RubyLLM.moderate' do
      expect(RubyLLM).to receive(:moderate).with('hello')

      described_class.moderate('hello')
    end
  end
end
