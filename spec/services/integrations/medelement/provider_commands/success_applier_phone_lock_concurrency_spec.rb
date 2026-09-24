require 'rails_helper'
require 'timeout'

RSpec.describe Integrations::Medelement::ProviderCommands::SuccessApplier do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:contact) do
    create(:contact, account: account, phone_number: '+15551234567',
                     custom_attributes: { 'medelement_patient_code' => 'patient-1' })
  end
  let(:mergee) { create(:contact, account: account, owner: admin) }
  let(:run) do
    Integrations::Medelement::SyncRun.create!(account: account, hook: hook, trigger: 'manual', status: 'partial')
  end
  let(:conflict) do
    Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
      phase: 'contacts', entity_type: 'contact', conflict_type: 'phone_mismatch',
      entity_key: 'patient-1', details: { contact_id: contact.id }
    )
  end
  let(:provider_phone) { '+15551230002' }
  let(:command) do
    metadata = {
      'conflict_id' => conflict.id, 'contact_id' => contact.id, 'user_id' => admin.id,
      'directions' => { 'phone' => 'medelement_to_onelink' },
      'provider' => { 'phone' => provider_phone }, 'desired_provider' => { 'phone' => provider_phone }
    }
    metadata['fingerprint'] = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(metadata)
    Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, contact: contact, operation: 'update_patient', status: 'processing',
      provider_patient_code: 'patient-1', idempotency_key: 'inbound-phone-race',
      execution_state: { 'contact_field_resolution' => metadata }
    )
  end

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true, destroy!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  after do
    Integrations::Medelement::ProviderCommand.where(account_id: account.id).destroy_all
    Integrations::Medelement::SyncConflict.where(account_id: account.id).destroy_all
    Integrations::Medelement::SyncRun.where(account_id: account.id).destroy_all
    Integrations::Hook.where(account_id: account.id).destroy_all
    Contact.where(account_id: account.id).destroy_all
    admin.destroy! if admin.persisted?
    account.destroy! if account.persisted?
  end

  it 'orders provider-success phone advisory before Contact rows even when merging concurrently' do
    command
    mergee
    applier = described_class.new(command: command)
    contact_locked = Queue.new
    release = Queue.new
    merger_started = Queue.new
    allow(applier).to receive(:link_contact_patient_ref!).and_wrap_original do |original, *args|
      original.call(*args)
      contact_locked << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
      release.pop
    end

    applier_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { applier.patient!(patient_code: 'patient-1') }
    rescue StandardError => e
      e
    end
    applier_pid = Timeout.timeout(15) { contact_locked.pop }
    merger_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        merger_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        ContactMergeAction.new(account: account, base_contact: Contact.find(contact.id), mergee_contact: Contact.find(mergee.id)).perform
      end
    rescue StandardError => e
      e
    end
    merger_pid = Timeout.timeout(15) { merger_started.pop }
    Timeout.timeout(15) do
      sleep 0.01 until ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{merger_pid})").include?(applier_pid.to_s)
    end
    expect(ActiveRecord::Base.connection.select_value("SELECT wait_event FROM pg_stat_activity WHERE pid = #{merger_pid}")).to eq('advisory')
    release << true
    applied = Timeout.timeout(15) { applier_thread.value }
    merged = Timeout.timeout(15) { merger_thread.value }
    raise applied if applied.is_a?(StandardError)
    raise merged if merged.is_a?(StandardError)

    expect(command.reload).to be_succeeded
    expect(conflict.reload).to be_resolved
    expect(contact.reload).to have_attributes(phone_number: provider_phone, owner_id: admin.id)
    expect(contact.custom_attributes['medelement_patient_code']).to eq('patient-1')
    expect(Contact.exists?(mergee.id)).to be false
  ensure
    release&.push(true)
    [applier_thread, merger_thread].compact.each do |thread|
      Timeout.timeout(15) { thread.value } if thread.alive?
    end
  end
end
