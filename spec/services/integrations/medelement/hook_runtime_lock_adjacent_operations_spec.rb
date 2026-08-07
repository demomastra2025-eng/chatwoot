require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::HookRuntimeLock do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:catalog_payload) do
    {
      'specialists' => [{ 'specialistCode' => 'SPEC-1', 'fullName' => 'Specialist' }],
      'cabinets' => [],
      'services' => [{ 'serviceCode' => 'SVC-1', 'name' => 'Service' }],
      'specialistServices' => [{ 'specialistCode' => 'SPEC-1', 'serviceCode' => 'SVC-1' }]
    }
  end
  let(:configuration) { instance_double(Integrations::Medelement::Configuration, time_zone: 'Asia/Almaty') }
  let(:cron_schedule) do
    instance_double(Integrations::Medelement::CronScheduleService, destroy!: true, sync!: true)
  end
  let(:specialists_sync) do
    instance_double(
      Integrations::Medelement::SpecialistsSyncService,
      perform: { imported_count: 1, skipped_count: 0 }
    )
  end
  let(:services_sync) do
    instance_double(
      Integrations::Medelement::ServicesSyncService,
      perform: { imported_count: 1, linked_count: 1, skipped_count: 0 }
    )
  end

  before do
    account.enable_features!('scheduling')
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(cron_schedule)
    hook
    allow(Integrations::Medelement::Configuration).to receive(:new).and_return(configuration)
    allow(Integrations::Medelement::SpecialistsSyncService).to receive(:new).and_return(specialists_sync)
    allow(Integrations::Medelement::ServicesSyncService).to receive(:new).and_return(services_sync)
  end

  after do
    Integrations::Medelement::SyncRun.where(account_id: account.id).delete_all
    Integrations::Hook.where(id: hook.id).delete_all
    account.destroy! if Account.exists?(account.id)
  end

  it 'makes destroy abort when scheduled admission creates an active run first' do
    acquired = Queue.new
    release = Queue.new
    errors = Queue.new
    operation_result = Queue.new
    start = Queue.new
    operation_thread = Thread.new do
      start.pop
      with_connection(errors) do
        stale_hook = Integrations::Hook.find(hook.id)
        operation_result << Integrations::Medelement::SyncJob.new.send(:create_scheduled_sync_run, stale_hook)
      end
    end
    pause_after_lock(operation_thread, acquired, release)
    start << true
    Timeout.timeout(3) { acquired.pop }

    destroy_result = Queue.new
    destroy_thread = Thread.new do
      with_connection(errors) { destroy_result << Integrations::Hook.find(hook.id).destroy }
    end
    expect { Timeout.timeout(0.2) { destroy_result.pop } }.to raise_error(Timeout::Error)

    release << true
    run = Timeout.timeout(3) { operation_result.pop }
    expect(Timeout.timeout(3) { destroy_result.pop }).to be(false)
    join_threads(operation_thread, destroy_thread)
    raise errors.pop unless errors.empty?

    expect(run).to be_queued
    expect(Integrations::Hook.exists?(hook.id)).to be(true)
  ensure
    release << true if operation_thread&.alive?
    operation_thread&.join(1)
    destroy_thread&.join(1)
  end

  it 'rejects scheduled admission when destroy commits first' do
    acquired = Queue.new
    release = Queue.new
    errors = Queue.new
    destroy_result = Queue.new
    start = Queue.new
    destroy_thread = Thread.new do
      start.pop
      with_connection(errors) { destroy_result << Integrations::Hook.find(hook.id).destroy }
    end
    pause_after_lock(destroy_thread, acquired, release)
    start << true
    Timeout.timeout(3) { acquired.pop }

    operation_thread = Thread.new do
      with_connection(errors) do
        Integrations::Medelement::SyncJob.new.send(:create_scheduled_sync_run, hook)
      end
    end
    release << true
    expect(Timeout.timeout(3) { destroy_result.pop }).to be_truthy
    join_threads(destroy_thread, operation_thread)

    expect(errors.pop).to be_a(ActiveRecord::RecordNotFound)
    expect(Integrations::Medelement::SyncRun.where(hook_id: hook.id)).to be_empty
  ensure
    release << true if destroy_thread&.alive?
    destroy_thread&.join(1)
    operation_thread&.join(1)
  end

  it 'holds teardown until catalog import finishes' do
    acquired = Queue.new
    release = Queue.new
    errors = Queue.new
    operation_result = Queue.new
    start = Queue.new
    service = Integrations::Medelement::CatalogImportService.new(hook: hook, payload: catalog_payload)
    operation_thread = Thread.new do
      start.pop
      with_connection(errors) { operation_result << service.perform }
    end
    pause_after_lock(operation_thread, acquired, release)
    start << true
    Timeout.timeout(3) { acquired.pop }

    destroy_result = Queue.new
    destroy_thread = Thread.new do
      with_connection(errors) { destroy_result << Integrations::Hook.find(hook.id).destroy }
    end
    expect { Timeout.timeout(0.2) { destroy_result.pop } }.to raise_error(Timeout::Error)

    release << true
    expect(Timeout.timeout(3) { operation_result.pop }).to include(
      specialists: { imported_count: 1, skipped_count: 0 },
      services: { imported_count: 1, linked_count: 1, skipped_count: 0 }
    )
    expect(Timeout.timeout(3) { destroy_result.pop }).to be_truthy
    join_threads(operation_thread, destroy_thread)
    raise errors.pop unless errors.empty?

    expect(Integrations::Hook.exists?(hook.id)).to be(false)
  ensure
    release << true if operation_thread&.alive?
    operation_thread&.join(1)
    destroy_thread&.join(1)
  end

  it 'rejects catalog import before any sync service runs when destroy commits first' do
    acquired = Queue.new
    release = Queue.new
    errors = Queue.new
    destroy_result = Queue.new
    start = Queue.new
    destroy_thread = Thread.new do
      start.pop
      with_connection(errors) { destroy_result << Integrations::Hook.find(hook.id).destroy }
    end
    pause_after_lock(destroy_thread, acquired, release)
    start << true
    Timeout.timeout(3) { acquired.pop }

    service = Integrations::Medelement::CatalogImportService.new(hook: hook, payload: catalog_payload)
    operation_thread = Thread.new { with_connection(errors) { service.perform } }
    release << true
    expect(Timeout.timeout(3) { destroy_result.pop }).to be_truthy
    join_threads(destroy_thread, operation_thread)

    expect(errors.pop).to be_a(ActiveRecord::RecordNotFound)
    expect(Integrations::Medelement::SpecialistsSyncService).not_to have_received(:new)
    expect(Integrations::Medelement::ServicesSyncService).not_to have_received(:new)
  ensure
    release << true if destroy_thread&.alive?
    destroy_thread&.join(1)
    operation_thread&.join(1)
  end

  private

  def pause_after_lock(thread, acquired, release)
    allow(described_class).to receive(:acquire!).and_wrap_original do |method, **arguments|
      method.call(**arguments)
      next unless Thread.current == thread

      acquired << true
      release.pop
    end
  end

  def with_connection(errors, &)
    ActiveRecord::Base.connection_pool.with_connection(&)
  rescue StandardError => e
    errors << e
  end

  def join_threads(*threads)
    threads.each { |thread| Timeout.timeout(3) { thread.join } }
  end
end
