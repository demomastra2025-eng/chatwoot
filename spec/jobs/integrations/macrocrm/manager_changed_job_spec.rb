require 'rails_helper'

RSpec.describe Integrations::Macrocrm::ManagerChangedJob do
  let(:lock_manager) { instance_double(Redis::LockManager) }
  let(:account) { create(:account) }
  let(:hook) do
    create(:integrations_hook,
           account: account,
           app_id: 'macrocrm',
           access_token: 'macro-secret',
           settings: { 'app_id' => 'macro-app' })
  end
  let(:payload) do
    {
      'action' => 'estate.managerChanged',
      'data' => { 'event' => 'estate.managerChanged' }
    }
  end
  let(:processor_service) do
    instance_double(Integrations::Macrocrm::ManagerChangedProcessorService, perform: true)
  end

  before do
    allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
    allow(lock_manager).to receive(:lock).and_return(true)
    allow(lock_manager).to receive(:unlock).and_return(true)
    allow(Integrations::Macrocrm::ManagerChangedProcessorService).to receive(:new).and_return(processor_service)
  end

  it 'runs on the medium queue' do
    expect(described_class.queue_name).to eq('medium')
  end

  it 'processes manager_changed under a per-hook lock' do
    expect(lock_manager).to receive(:lock).with(
      format(Redis::Alfred::CRM_PROCESS_MUTEX, hook_id: hook.id),
      30.seconds
    ).and_return(true)
    expect(Integrations::Macrocrm::ManagerChangedProcessorService)
      .to receive(:new)
      .with(hook: hook, payload: payload)
      .and_return(processor_service)
    expect(processor_service).to receive(:perform)

    described_class.perform_now(hook.id, payload)
  end
end
