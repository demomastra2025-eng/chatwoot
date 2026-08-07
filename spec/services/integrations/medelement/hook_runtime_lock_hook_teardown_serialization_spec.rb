require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::HookRuntimeLock do
  self.use_transactional_tests = false

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true, destroy!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::SyncJob).to receive(:perform_later)
  end

  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  after do
    Integrations::Medelement::SyncRun.where(account_id: account.id).delete_all
    Integrations::Medelement::ProviderCommand.where(account_id: account.id).delete_all
    Integrations::Hook.where(id: hook.id).delete_all
    account.destroy!
  end

  it 'lets the committed launch make the waiting destroy abort' do
    locked = Queue.new
    release = Queue.new
    launcher_result = Queue.new
    destroy_result = Queue.new
    errors = Queue.new
    launcher_start = Queue.new
    launcher_thread = Thread.new do
      launcher_start.pop
      with_connection(errors) do
        runtime_hook = Integrations::Hook.find(hook.id)
        launcher_result << Integrations::Medelement::SyncRunLauncher.new(hook: runtime_hook).perform
      end
    end
    allow(described_class).to receive(:acquire!).and_wrap_original do |method, **arguments|
      method.call(**arguments)
      if Thread.current == launcher_thread
        locked << true
        release.pop
      end
    end
    launcher_start << true
    Timeout.timeout(2) { locked.pop }

    destroy_thread = Thread.new do
      with_connection(errors) { destroy_result << Integrations::Hook.find(hook.id).destroy }
    end
    expect { Timeout.timeout(0.2) { destroy_result.pop } }.to raise_error(Timeout::Error)

    release << true
    run, enqueued = Timeout.timeout(5) { launcher_result.pop }
    expect([run.persisted?, enqueued]).to eq([true, true])
    expect(Timeout.timeout(5) { destroy_result.pop }).to be(false)
    expect(Integrations::Hook).to exist(hook.id)
    expect(Integrations::Medelement::SyncRun.active).to exist(hook_id: hook.id)
    expect(errors).to be_empty
    [launcher_thread, destroy_thread].each(&:join)
  ensure
    release&.push(true) if launcher_thread&.alive?
    cleanup_threads(launcher_thread, destroy_thread)
  end

  it 'makes the waiting launcher fail closed after destroy commits' do
    locked = Queue.new
    release = Queue.new
    destroy_result = Queue.new
    launcher_result = Queue.new
    errors = Queue.new
    destroy_start = Queue.new
    destroy_thread = Thread.new do
      destroy_start.pop
      with_connection(errors) { destroy_result << Integrations::Hook.find(hook.id).destroy }
    end
    allow(described_class).to receive(:acquire!).and_wrap_original do |method, **arguments|
      method.call(**arguments)
      if Thread.current == destroy_thread
        locked << true
        release.pop
      end
    end
    stale_hook = hook
    destroy_start << true
    Timeout.timeout(2) { locked.pop }

    launcher_thread = Thread.new do
      with_connection(errors) do
        launcher_result << Integrations::Medelement::SyncRunLauncher.new(hook: stale_hook).perform
      rescue ActiveRecord::RecordNotFound
        launcher_result << :hook_deleted
      end
    end
    expect { Timeout.timeout(0.2) { launcher_result.pop } }.to raise_error(Timeout::Error)

    release << true
    expect(Timeout.timeout(5) { destroy_result.pop }).to be_truthy
    expect(Timeout.timeout(5) { launcher_result.pop }).to eq(:hook_deleted)
    expect(Integrations::Hook).not_to exist(hook.id)
    expect(Integrations::Medelement::SyncRun).not_to exist(hook_id: hook.id)
    expect(errors).to be_empty
    [destroy_thread, launcher_thread].each(&:join)
  ensure
    release&.push(true) if destroy_thread&.alive?
    cleanup_threads(destroy_thread, launcher_thread)
  end

  def with_connection(errors, &)
    ActiveRecord::Base.connection_pool.with_connection(&)
  rescue StandardError => e
    errors << e
  end

  def cleanup_threads(*threads)
    threads.compact.each do |thread|
      thread.join(2)
      thread.kill if thread.alive?
    end
  end
end
