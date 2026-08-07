require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommand, type: :model do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) { create(:contact, account: account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true, destroy!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  it 'rejects cross-account associations' do
    command = described_class.new(
      account: account,
      hook: hook,
      contact: create(:contact),
      operation: 'create_patient',
      status: 'failed',
      idempotency_key: 'cross-account-contact'
    )

    expect(command).not_to be_valid
    expect(command.errors[:contact]).to include('must belong to the current account')
  end

  it 'enforces one unfinished patient identity command across contact and appointment targets in PostgreSQL' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'queued',
      idempotency_key: 'first-command'
    )
    resource = create(:scheduling_resource, account: account)
    appointment = create(:scheduling_appointment, account: account, contact: contact, resource: resource)
    duplicate_attributes = command.attributes.except('id').merge(
      'appointment_id' => appointment.id,
      'operation' => 'create_reception',
      'provider_patient_code' => '',
      'company_cabinet_code' => 'cabinet-1',
      'idempotency_key' => 'second-command',
      'created_at' => Time.current,
      'updated_at' => Time.current
    )

    # Bypassing validations is intentional: this verifies the database race barrier itself.
    # rubocop:disable Rails/SkipsModelValidations
    expect { described_class.insert_all!([duplicate_attributes]) }.to raise_error(ActiveRecord::RecordNotUnique)
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'serializes unfinished patient updates for the same contact in PostgreSQL' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'update_patient',
      status: 'queued',
      provider_patient_code: 'patient-1',
      idempotency_key: 'first-update'
    )
    duplicate_attributes = command.attributes.except('id').merge(
      'idempotency_key' => 'second-update',
      'created_at' => Time.current,
      'updated_at' => Time.current
    )

    # Bypassing validations is intentional: this verifies the database race barrier itself.
    # rubocop:disable Rails/SkipsModelValidations
    expect { described_class.insert_all!([duplicate_attributes]) }.to raise_error(ActiveRecord::RecordNotUnique)
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'keeps patient-action waiting states inside the unfinished database barrier' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'awaiting_patient_creation',
      idempotency_key: 'awaiting-patient-action'
    )
    duplicate_attributes = command.attributes.except('id').merge(
      'status' => 'queued',
      'idempotency_key' => 'duplicate-during-patient-action',
      'created_at' => Time.current,
      'updated_at' => Time.current
    )

    # Bypassing validations is intentional: this verifies the database race barrier itself.
    # rubocop:disable Rails/SkipsModelValidations
    expect { described_class.insert_all!([duplicate_attributes]) }.to raise_error(ActiveRecord::RecordNotUnique)
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'keeps versioned statuses logical to current code and invisible to legacy exact scopes' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'v2_queued',
      idempotency_key: 'versioned-command'
    )

    expect(command).to be_queued
    expect(command).to be_versioned_execution
    expect(command.logical_status).to eq('queued')
    expect(command.status_for_transition('processing')).to eq('v2_processing')
    expect(described_class.executable).to include(command)
    expect(described_class.where(status: 'queued')).not_to include(command)
  end

  it 'keeps versioned patient-action states inside the unfinished database barrier' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'v2_awaiting_patient_creation',
      idempotency_key: 'versioned-patient-action'
    )
    duplicate_attributes = command.attributes.except('id').merge(
      'status' => 'queued',
      'idempotency_key' => 'duplicate-versioned-patient-action',
      'created_at' => Time.current,
      'updated_at' => Time.current
    )

    # Bypassing validations is intentional: this verifies the database race barrier itself.
    # rubocop:disable Rails/SkipsModelValidations
    expect { described_class.insert_all!([duplicate_attributes]) }.to raise_error(ActiveRecord::RecordNotUnique)
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'blocks hook deletion while a provider command is unfinished' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'queued',
      idempotency_key: 'unfinished-hook-command'
    )

    expect(hook.destroy).to be(false)
    expect(hook.errors[:base]).to include('Cannot remove Medelement integration while provider commands are unfinished')
    expect(command.reload.hook).to eq(hook)
  end

  it 'preserves terminal command audit after its hook is deleted' do
    command = described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'succeeded',
      idempotency_key: 'terminal-hook-command'
    )

    hook.destroy!

    expect(command.reload).to have_attributes(hook_id: nil, status: 'succeeded')
  end

  it 'rejects a contact that does not match the appointment' do
    resource = create(:scheduling_resource, account: account)
    appointment = create(:scheduling_appointment, account: account, contact: contact, resource: resource)
    command = described_class.new(
      account: account,
      hook: hook,
      appointment: appointment,
      contact: create(:contact, account: account),
      operation: 'remove_reception',
      status: 'failed',
      provider_reception_code: 'reception-1',
      idempotency_key: 'wrong-contact'
    )

    expect(command).not_to be_valid
    expect(command.errors[:contact]).to include('must match the appointment contact')
  end

  it 'allows a new command after the earlier command becomes terminal' do
    described_class.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: 'failed',
      idempotency_key: 'terminal-command'
    )

    expect do
      described_class.create!(
        account: account,
        hook: hook,
        contact: contact,
        operation: 'create_patient',
        status: 'awaiting_confirmation',
        idempotency_key: 'next-command'
      )
    end.to change(described_class, :count).by(1)
  end
end
