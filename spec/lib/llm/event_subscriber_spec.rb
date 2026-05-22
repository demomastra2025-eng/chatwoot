# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::EventSubscriber do
  describe '.install!' do
    it 'routes llm notifications to the monitoring recorder' do
      allow(Llm::Monitoring::EventRecorder).to receive(:record_notification)
      allow(Llm::Monitoring::OtelEventExporter).to receive(:export_notification)

      described_class.install!
      Llm::EventBus.publish('chat.complete', feature: 'assistant', model: 'gpt-4.1-mini')

      expect(Llm::Monitoring::EventRecorder).to have_received(:record_notification) do |**args|
        expect(args[:event_name]).to eq('llm.chat.complete')
        expect(args[:payload]).to include('feature' => 'assistant', 'model' => 'gpt-4.1-mini')
      end
      expect(Llm::Monitoring::OtelEventExporter).to have_received(:export_notification) do |**args|
        expect(args[:event_name]).to eq('llm.chat.complete')
        expect(args[:payload]).to include('feature' => 'assistant', 'model' => 'gpt-4.1-mini')
      end
    ensure
      described_class.uninstall!
    end

    it 'keeps recorder delivery isolated if the OTel exporter raises unexpectedly' do
      allow(Llm::Monitoring::EventRecorder).to receive(:record_notification)
      allow(Llm::Monitoring::OtelEventExporter).to receive(:export_notification).and_raise(StandardError, 'otel bug')

      described_class.install!

      expect do
        Llm::EventBus.publish('chat.complete', feature: 'assistant', model: 'gpt-4.1-mini')
      end.not_to raise_error

      expect(Llm::Monitoring::EventRecorder).to have_received(:record_notification)
    ensure
      described_class.uninstall!
    end
  end
end
