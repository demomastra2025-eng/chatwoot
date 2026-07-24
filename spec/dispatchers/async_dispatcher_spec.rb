require 'rails_helper'
describe AsyncDispatcher do
  subject(:dispatcher) { described_class.new }

  let!(:conversation) { create(:conversation) }
  let(:event_name) { 'conversation.created' }
  let(:timestamp) { Time.zone.now }
  let(:event_data) { { conversation: conversation } }

  describe '#dispatch' do
    it 'enqueue job to dispatch event' do
      expect(EventDispatcherJob).to receive(:perform_later).with(event_name, timestamp, event_data).once
      dispatcher.dispatch(event_name, timestamp, event_data)
    end

    it 'uses the dedicated realtime queue for voice-call message events' do
      message = create(:message, conversation: conversation, content_type: :voice_call)
      configured_job = instance_double(ActiveJob::ConfiguredJob)
      data = { message: message }

      expect(EventDispatcherJob).to receive(:set).with(queue: :telephony_realtime).and_return(configured_job)
      expect(configured_job).to receive(:perform_later).with('message.updated', timestamp, data)

      dispatcher.dispatch('message.updated', timestamp, data)
    end
  end

  describe '#listeners' do
    it 'registers WhatsApp typing propagation' do
      expect(dispatcher.listeners).to include(WhatsappTypingListener.instance)
    end
  end
end
