require 'rails_helper'

RSpec.describe Integrations::Macrocrm::SyncJob do
  let(:lock_manager) { instance_double(Redis::LockManager) }
  let(:account) { create(:account) }
  let(:hook) do
    create(:integrations_hook,
           account: account,
           app_id: 'macrocrm',
           access_token: 'macro-secret',
           settings: { 'app_id' => 'macro-app' })
  end
  let(:message) { create(:message, account: account, content: 'Hello from WhatsApp', message_type: :incoming) }
  let(:processor_service) { instance_double(Integrations::Macrocrm::ProcessorService, perform: true) }

  before do
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(lock_manager).to receive(:lock).and_return(true)
    allow(lock_manager).to receive(:unlock).and_return(true)
    allow(Integrations::Macrocrm::ProcessorService).to receive(:new).and_return(processor_service)
  end

  it 'runs on the medium queue' do
    expect(described_class.queue_name).to eq('medium')
  end

  it 'processes the sync under a per-hook lock' do
    expect(lock_manager).to receive(:lock).with(
      format(Redis::Alfred::MACROCRM_SYNC_MUTEX, hook_id: hook.id, conversation_id: message.conversation_id),
      30.seconds
    ).and_return(true)
    expect(Integrations::Macrocrm::ProcessorService)
      .to receive(:new)
      .with(hook: hook, event_name: 'message.created', message: message)
      .and_return(processor_service)
    expect(processor_service).to receive(:perform)

    described_class.perform_now(hook.id, 'message.created', message.id)
  end

  it 'uses the lock-specific retry policy for lock acquisition failures' do
    allow(lock_manager).to receive(:lock).and_return(false)

    freeze_time do
      clear_enqueued_jobs

      expect do
        described_class.perform_now(hook.id, 'message.created', message.id)
      end.to have_enqueued_job(described_class).with(hook.id, 'message.created', message.id).on_queue('medium')

      expect(Time.zone.at(enqueued_jobs.last[:at])).to be_within(1.second).of(5.seconds.from_now)
    end
  end
end
