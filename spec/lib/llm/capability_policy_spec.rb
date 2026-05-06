# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::CapabilityPolicy do
  describe '.ensure_chat_features_supported!' do
    let(:schema) do
      Class.new(RubyLLM::Schema) do
        string :message
      end
    end
    let(:tool) { instance_double(RubyLLM::Tool) }

    it 'allows supported structured outputs and tool calling' do
      expect do
        described_class.ensure_chat_features_supported!(
          model: 'gpt-4.1-mini',
          schema: schema,
          tools: [tool]
        )
      end.not_to raise_error
    end

    it 'raises for unsupported structured outputs' do
      expect do
        described_class.ensure_chat_features_supported!(model: 'whisper-1', schema: schema)
      end.to raise_error(described_class::UnsupportedCapabilityError, /structured outputs/)
    end

    it 'raises for unsupported tool calling' do
      expect do
        described_class.ensure_chat_features_supported!(model: 'text-embedding-3-small', tools: [tool])
      end.to raise_error(described_class::UnsupportedCapabilityError, /tool calling/)
    end
  end

  describe '.ensure_input_supported!' do
    it 'allows text-only content even for non-multimodal models' do
      expect do
        described_class.ensure_input_supported!(model: 'whisper-1', content: RubyLLM::Content.new('Hello'))
      end.not_to raise_error
    end

    it 'allows image attachments for image-input-only models' do
      allow(Llm::Models).to receive(:supports?).and_call_original
      allow(Llm::Models).to receive(:supports?).with('image-only-model', :image_input, account: nil).and_return(true)
      content = RubyLLM::Content.new('Inspect this', ['https://example.com/image.png'])

      expect do
        described_class.ensure_input_supported!(model: 'image-only-model', content: content)
      end.not_to raise_error
    end

    it 'allows audio attachments for audio-input-only models' do
      allow(Llm::Models).to receive(:supports?).and_call_original
      allow(Llm::Models).to receive(:supports?).with('audio-only-model', :audio_input, account: nil).and_return(true)
      content = RubyLLM::Content.new('Transcribe this', ['https://example.com/audio.mp3'])

      expect do
        described_class.ensure_input_supported!(model: 'audio-only-model', content: content)
      end.not_to raise_error
    end

    it 'raises for unsupported image input' do
      content = RubyLLM::Content.new('Inspect this', ['https://example.com/image.png'])

      expect do
        described_class.ensure_input_supported!(model: 'whisper-1', content: content)
      end.to raise_error(described_class::UnsupportedCapabilityError, /image inputs/)
    end
  end
end
