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

    it 'uses the provided scoped context instead of global RubyLLM when present' do
      context = double('context')
      response = double('embedding')

      expect(context).to receive(:embed).with('hello', model: 'text-embedding-3-small').and_return(response)
      expect(RubyLLM).not_to receive(:embed)

      expect(described_class.embed('hello', context: context, model: 'text-embedding-3-small')).to eq(response)
    end

    it 'publishes an embedding event when observability payload is provided' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.embedding.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      response = double('embedding', vectors: [0.1, 0.2, 0.3], input_tokens: 9)
      allow(RubyLLM).to receive(:embed).and_return(response)

      result = described_class.embed(
        'hello',
        model: 'text-embedding-3-small',
        observability: { feature_name: 'embedding', account_id: 1 }
      )

      expect(result).to eq(response)
      expect(events.last.payload).to include(
        'feature' => 'embedding',
        'account_id' => 1,
        'status' => 'success',
        'prompt_tokens' => 9,
        'total_tokens' => 9,
        'vector_count' => 1,
        'dimensions' => 3
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end

  describe '.moderate' do
    it 'delegates to RubyLLM.moderate' do
      expect(RubyLLM).to receive(:moderate).with('hello')

      described_class.moderate('hello')
    end

    it 'uses the provided scoped context for moderation when present' do
      context = double('context')
      response = instance_double(RubyLLM::Moderation, flagged?: false)

      expect(context).to receive(:moderate).with('hello', model: 'safe-model').and_return(response)
      expect(RubyLLM).not_to receive(:moderate)

      expect(described_class.moderate('hello', context: context, model: 'safe-model')).to eq(response)
    end

    it 'publishes a moderation event when observability payload is provided' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.moderation.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      response = instance_double(RubyLLM::Moderation, flagged?: false, flagged_categories: [])
      allow(RubyLLM).to receive(:moderate).and_return(response)

      result = described_class.moderate(
        'hello',
        observability: { feature_name: 'content_evaluator', model: 'omni-moderation-latest' }
      )

      expect(result).to eq(response)
      expect(events.last.payload).to include(
        'feature' => 'content_evaluator',
        'model' => 'omni-moderation-latest',
        'status' => 'allowed',
        'blocked' => false
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end

  describe '.transcribe' do
    it 'delegates to RubyLLM.transcribe' do
      expect(RubyLLM).to receive(:transcribe).with('/tmp/audio.mp3', model: 'whisper-1')

      described_class.transcribe('/tmp/audio.mp3', model: 'whisper-1')
    end

    it 'uses the provided scoped context for transcription when present' do
      context = double('context')
      response = double('transcription', text: 'hello')

      expect(context).to receive(:transcribe).with('/tmp/audio.mp3', model: 'whisper-1').and_return(response)
      expect(RubyLLM).not_to receive(:transcribe)

      expect(described_class.transcribe('/tmp/audio.mp3', context: context, model: 'whisper-1')).to eq(response)
    end

    it 'publishes a transcription event when observability payload is provided' do
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('llm.transcription.complete') do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
      response = double('transcription', text: 'hello audio', input_tokens: nil, output_tokens: nil)
      allow(RubyLLM).to receive(:transcribe).and_return(response)

      result = described_class.transcribe(
        '/tmp/audio.mp3',
        model: 'whisper-1',
        observability: { feature_name: 'audio_transcription', account_id: 1 }
      )

      expect(result).to eq(response)
      expect(events.last.payload).to include(
        'feature' => 'audio_transcription',
        'account_id' => 1,
        'model' => 'whisper-1',
        'status' => 'success',
        'output_type' => 'text',
        'output_size' => 11
      )
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end
end
