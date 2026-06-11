# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ModerationService do
  describe '.check!' do
    let(:chat) { instance_double(RubyLLM::Chat) }
    let(:model) { 'openai/gpt-oss-safeguard-20b' }
    let(:response_payload) { { 'flagged' => false, 'categories' => [], 'reason' => 'safe' } }
    let(:response) { instance_double(RubyLLM::Message, content: response_payload) }
    let(:events) { [] }
    let(:subscriber) do
      ActiveSupport::Notifications.subscribe(/llm\.(moderation|safety)\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
    end

    before do
      subscriber
      allow(Llm::RuntimePolicy).to receive(:moderation_enabled?).and_return(true)
      allow(Llm::RuntimePolicy).to receive(:fail_closed_moderation?).and_return(false)
      allow(Llm::RuntimePolicy).to receive(:moderation_failure_mode).and_return('fail_open')
      allow(Llm::Config).to receive(:api_key).with('openrouter').and_return('openrouter-key')
      allow(Llm::Config).to receive(:moderation_model).and_return(model)
      allow(Llm::Config).to receive(:provider_for_model).with(model, account: nil).and_return('openrouter')
      allow(Llm::OpenRouterModelMigration).to receive(:resolve).and_return(model)
      allow(Llm::Models).to receive(:supports_structured_output?).with(model).and_return(true)
      allow(Llm::Runtime).to receive(:build_chat).with(
        feature: :moderation,
        account: nil,
        model: model,
        options: { temperature: 0 }
      ).and_return(chat)
      allow(Llm::StructuredOutputPolicy).to receive(:bind!).with(chat: chat, schema: kind_of(Hash)).and_return(chat)
      allow(Llm::Runtime).to receive(:ask).and_return(response)
    end

    after do
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'returns an allowed result when moderation passes' do
      result = described_class.check!(feature: :assistant, stage: :input, content: 'Hello')

      expect(result.status).to eq(:allowed)
      expect(result.feature).to eq(:assistant)
      expect(result.stage).to eq(:input)
      expect(result.provider).to eq('openrouter')
      expect(result.model).to eq(model)
      expect(result.result).not_to be_flagged
      expect(events.last.name).to eq('llm.moderation.complete')
      expect(events.last.payload).to include(
        'status' => :allowed,
        'feature' => :assistant,
        'stage' => :input
      )
    end

    it 'uses an OpenRouter guard chat model instead of the OpenAI moderation endpoint when OpenRouter is selected' do
      expect(Llm::ApiClient).not_to receive(:moderate)
      expect(Llm::Runtime).to receive(:ask).with(
        chat,
        include('Content:', 'Hello'),
        hash_including(
          observability: hash_including(provider: 'openrouter', model: model)
        )
      ).and_return(response)

      result = described_class.check!(feature: :assistant, stage: :input, content: 'Hello')

      expect(result.status).to eq(:allowed)
      expect(result.provider).to eq('openrouter')
      expect(result.result).not_to be_flagged
    end

    it 'returns a skipped result when moderation is unavailable in fail_open mode' do
      allow(Llm::Config).to receive(:api_key).with('openrouter').and_return(nil)

      result = described_class.check!(feature: :assistant, stage: :input, content: 'Hello')

      expect(result.status).to eq(:skipped)
      expect(result.reason).to eq(:provider_not_configured)
      expect(events.last.name).to eq('llm.moderation.unavailable')
      expect(events.last.payload).to include(
        'reason' => :provider_not_configured,
        'failure_mode' => 'fail_open'
      )
    end

    it 'returns disabled without resolving provider configuration when moderation is disabled' do
      allow(Llm::RuntimePolicy).to receive(:moderation_enabled?).and_return(false)

      expect(Llm::Config).not_to receive(:moderation_model)
      expect(Llm::Config).not_to receive(:provider_for_model)
      expect(Llm::Runtime).not_to receive(:build_chat)

      result = described_class.check!(
        feature: :assistant,
        stage: :output,
        content: 'Hello'
      )

      expect(result.status).to eq(:disabled)
      expect(result.feature).to eq(:assistant)
      expect(result.stage).to eq(:output)
    end

    it 'raises when moderation is unavailable in fail_closed mode' do
      allow(Llm::Config).to receive(:api_key).with('openrouter').and_return(nil)
      allow(Llm::RuntimePolicy).to receive(:fail_closed_moderation?).and_return(true)
      allow(Llm::RuntimePolicy).to receive(:moderation_failure_mode).and_return('fail_closed')

      expect do
        described_class.check!(feature: :assistant, stage: :input, content: 'Hello')
      end.to raise_error(described_class::UnavailableError, /provider_not_configured/)

      moderation_event = events.find { |event| event.name == 'llm.moderation.unavailable' }
      expect(moderation_event).to be_present
      expect(moderation_event.payload).to include('failure_mode' => 'fail_closed')
      expect(events.map(&:name)).to include('llm.safety.blocked')
    end

    it 'raises when moderation flags the content' do
      allow(response).to receive(:content).and_return(
        { 'flagged' => true, 'categories' => ['violence'], 'reason' => 'unsafe' }
      )

      expect do
        described_class.check!(feature: :assistant, stage: :output, content: 'Hello')
      end.to raise_error(described_class::FlaggedContentError)

      expect(events.map(&:name)).to include('llm.moderation.complete', 'llm.safety.blocked')
    end

    it 'normalizes multimodal input before moderating' do
      described_class.check!(
        feature: :assistant,
        stage: :input,
        content: [
          { type: 'text', text: 'Look here' },
          { type: 'image_url', image_url: { url: 'https://example.com/image.png' } }
        ]
      )

      expect(Llm::Runtime).to have_received(:ask).with(
        chat,
        include('Content:', 'Look here'),
        hash_including(observability: hash_including(provider: 'openrouter', model: model))
      )
    end
  end
end
