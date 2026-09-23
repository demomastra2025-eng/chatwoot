require 'rails_helper'

RSpec.describe ActionCableBroadcastJob, type: :job do
  %w[message.created message.updated conversation.updated contact.updated notification.created].each do |event_name|
    it "routes #{event_name} broadcasts to the isolated broadcast queue" do
      job = described_class.new([], event_name, {})

      expect(job.queue_name).to eq('action_cable_realtime')
    end
  end

  it 'preserves the dedicated communication-thread queue' do
    job = described_class.new([], 'communication_thread.updated', {})

    expect(job.queue_name).to eq('communication_thread_realtime')
  end

  it 'preserves explicit telephony queue overrides' do
    job = described_class.set(queue: :telephony_realtime).perform_later([], 'message.created', {})

    expect(job.queue_name).to eq('telephony_realtime')
  end
end
