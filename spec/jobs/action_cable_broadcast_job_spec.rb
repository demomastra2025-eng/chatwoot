require 'rails_helper'

RSpec.describe ActionCableBroadcastJob, type: :job do
  it 'routes communication thread updates to the isolated realtime queue' do
    job = described_class.new([], 'communication_thread.updated', {})

    expect(job.queue_name).to eq('communication_thread_realtime')
  end

  it 'keeps other realtime events on the critical queue' do
    job = described_class.new([], 'message.created', {})

    expect(job.queue_name).to eq('critical')
  end
end
