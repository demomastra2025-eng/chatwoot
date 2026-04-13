# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ModerationService do
  describe '.check!' do
    let(:moderation_result) { instance_double(RubyLLM::Moderation, flagged?: false) }
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
      allow(Llm::Config).to receive(:api_key).with('openai').and_return('openai-key')
      allow(Llm::Config).to receive(:moderation_model).and_return('omni-moderation-latest')
      allow(Llm::ApiClient).to receive(:moderate).and_return(moderation_result)
    end

    after do
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'returns an allowed result when moderation passes' do
      result = described_class.check!(feature: :assistant, stage: :input, content: 'Hello')

      expect(result.status).to eq(:allowed)
      expect(result.feature).to eq(:assistant)
      expect(result.stage).to eq(:input)
      expect(result.provider).to eq('openai')
      expect(result.model).to eq('omni-moderation-latest')
      expect(result.result).to eq(moderation_result)
      expect(events.last.name).to eq('llm.moderation.complete')
      expect(events.last.payload).to include(
        'status' => :allowed,
        'feature' => :assistant,
        'stage' => :input
      )
    end

    it 'returns a skipped result when moderation is unavailable in fail_open mode' do
      allow(Llm::Config).to receive(:api_key).with('openai').and_return(nil)

      result = described_class.check!(feature: :assistant, stage: :input, content: 'Hello')

      expect(result.status).to eq(:skipped)
      expect(result.reason).to eq(:provider_not_configured)
      expect(events.last.name).to eq('llm.moderation.unavailable')
      expect(events.last.payload).to include(
        'reason' => :provider_not_configured,
        'failure_mode' => 'fail_open'
      )
    end

    it 'raises when moderation is unavailable in fail_closed mode' do
      allow(Llm::Config).to receive(:api_key).with('openai').and_return(nil)
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
      allow(moderation_result).to receive(:flagged?).and_return(true)

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

      expect(Llm::ApiClient).to have_received(:moderate).with(
        'Look here',
        model: 'omni-moderation-latest',
        provider: 'openai'
      )
    end
  end
end
