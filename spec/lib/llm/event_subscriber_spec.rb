# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::EventSubscriber do
  describe '.install!' do
    it 'routes llm notifications to the monitoring recorder' do
      allow(Llm::Monitoring::EventRecorder).to receive(:record_notification)

      described_class.install!
      Llm::EventBus.publish('chat.complete', feature: 'assistant', model: 'gpt-4.1-mini')

      expect(Llm::Monitoring::EventRecorder).to have_received(:record_notification) do |**args|
        expect(args[:event_name]).to eq('llm.chat.complete')
        expect(args[:payload]).to include('feature' => 'assistant', 'model' => 'gpt-4.1-mini')
      end
    ensure
      described_class.uninstall!
    end
  end
end
