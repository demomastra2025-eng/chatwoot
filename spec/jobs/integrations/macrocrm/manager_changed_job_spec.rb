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
      'data' => {
        'event' => 'estate.managerChanged',
        'object' => {
          'estate_id' => '12345'
        }
      }
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
      format(Redis::Alfred::MACROCRM_MANAGER_CHANGED_MUTEX, hook_id: hook.id, estate_id: '12345'),
      30.seconds
    ).and_return(true)
    expect(Integrations::Macrocrm::ManagerChangedProcessorService)
      .to receive(:new)
      .with(hook: hook, payload: payload)
      .and_return(processor_service)
    expect(processor_service).to receive(:perform)

    described_class.perform_now(hook.id, payload)
  end

  it 'uses the lock-specific retry policy for lock acquisition failures' do
    allow(lock_manager).to receive(:lock).and_return(false)

    freeze_time do
      clear_enqueued_jobs

      expect do
        described_class.perform_now(hook.id, payload)
      end.to have_enqueued_job(described_class).with(hook.id, payload).on_queue('medium')

      expect(Time.zone.at(enqueued_jobs.last[:at])).to be_within(1.second).of(5.seconds.from_now)
    end
  end

  it 'discards permanent MacroCRM errors without logging raw webhook payload' do
    sensitive_payload = payload.deep_dup
    sensitive_payload['data']['object']['client_phones'] = '+77001234567'
    error = Integrations::Macrocrm::Client::PermanentError.new(
      'upstream body contains sensitive customer data',
      endpoint: '/estateBuy/list',
      status: 422
    )
    warnings = []

    allow(processor_service).to receive(:perform).and_raise(error)
    allow(Rails.logger).to receive(:warn) { |message| warnings << message }

    described_class.perform_now(hook.id, sensitive_payload)

    log_output = warnings.join("\n")
    expect(log_output).to include("hook_id=#{hook.id}", 'estate_id=12345', 'endpoint=/estateBuy/list', 'status=422')
    expect(log_output).not_to include('client_phones', '+77001234567', 'sensitive customer data', 'job_arguments')
  end
end
