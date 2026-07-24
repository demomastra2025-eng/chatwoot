require 'rails_helper'

RSpec.describe Channels::WhatsappWeb::ProvisionJob do
  describe '#perform' do
    it 'uses the channel lifecycle boundary' do
      channel = instance_double(Channel::WhatsappWeb)
      allow(Channel::WhatsappWeb).to receive(:find_by).with(id: 42).and_return(channel)
      expect(channel).to receive(:provision!)

      described_class.perform_now(42)
    end

    it 'retries lock contention without marking the channel failed' do
      channel = instance_double(Channel::WhatsappWeb)
      allow(Channel::WhatsappWeb).to receive(:find_by).with(id: 42).and_return(channel)
      allow(channel).to receive(:provision!)
        .and_raise(WhatsappWeb::LifecycleLock::LockAcquisitionError, 'already in progress')
      expect(channel).not_to receive(:mark_failed!)

      expect { described_class.perform_now(42) }
        .to raise_error(WhatsappWeb::LifecycleLock::LockAcquisitionError)
    end
  end
end
