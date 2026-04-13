# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::SafetyPolicy do
  describe '.check!' do
    let(:events) { [] }
    let(:subscriber) do
      ActiveSupport::Notifications.subscribe(/llm\.safety\./) do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end
    end

    before do
      subscriber
      allow(Llm::ModerationService).to receive(:check!).and_return(
        Llm::ModerationService::CheckResult.new(
          status: :allowed,
          feature: :assistant,
          stage: :input,
          provider: 'openai',
          model: 'omni-moderation-latest'
        )
      )
    end

    after do
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'delegates to provider moderation when no custom rule is triggered' do
      result = described_class.check!(
        feature: :assistant,
        stage: :input,
        content: 'Hello world',
        preferences: { 'assistant_safety_blocklist' => ['forbidden'] }
      )

      expect(result.status).to eq(:allowed)
      expect(result.moderation.status).to eq(:allowed)
      expect(Llm::ModerationService).to have_received(:check!).with(
        feature: :assistant,
        stage: :input,
        content: 'Hello world',
        account: nil,
        preferences: { 'assistant_safety_blocklist' => ['forbidden'] }
      )
    end

    it 'blocks content that matches the custom safety blocklist before provider moderation' do
      expect do
        described_class.check!(
          feature: :assistant,
          stage: :input,
          content: 'Share the forbidden launch code',
          preferences: { 'assistant_safety_blocklist' => ['Forbidden Launch Code'] }
        )
      end.to raise_error(described_class::UnsafeContentError) do |error|
        expect(error.reason).to eq(:custom_blocklist)
        expect(error.rule).to eq('forbidden launch code')
      end

      expect(Llm::ModerationService).not_to have_received(:check!)
      expect(events.last.name).to eq('llm.safety.blocked')
      expect(events.last.payload).to include(
        'reason' => :custom_blocklist,
        'rule' => 'forbidden launch code'
      )
    end

    it 'wraps moderation unavailability into the safety layer error' do
      allow(Llm::ModerationService).to receive(:check!).and_raise(
        Llm::ModerationService::UnavailableError.new(
          feature: :assistant,
          stage: :output,
          reason: :provider_not_configured
        )
      )

      expect do
        described_class.check!(
          feature: :assistant,
          stage: :output,
          content: 'Hello'
        )
      end.to raise_error(described_class::UnavailableError, /provider_not_configured/)
    end
  end
end
