require 'rails_helper'

RSpec.describe Integrations::Medelement::PatientCardRepairService do
  let(:policy) { Integrations::Medelement::AppointmentPatientIdentity }
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:owner) do
    create(:contact, account: account, name: 'Primary', phone_number: '+77000000001',
                     custom_attributes: { 'medelement_patient_code' => 'relative-2', 'medelement_first_name' => 'Relative',
                                          'medelement_last_synced_at' => Time.current.iso8601 })
  end
  let(:conversation) { create(:conversation, account: account, contact: owner) }
  let!(:appointment) { owned_appointment }

  def owned_appointment(code: 'relative-2')
    create(:scheduling_appointment, account: account, contact: owner, conversation: conversation,
                                    client_first_name: 'Relative', client_last_name: 'Patient', client_middle_name: nil,
                                    client_name: 'Relative Patient', client_phone: owner.phone_number, client_identifier: '940720300129',
                                    custom_attributes: { policy::OWNED_IDENTITY_KEY => true,
                                                         policy::EXPLICIT_IDENTIFIER_KEY => true }).tap do |record|
      record.update_columns(custom_attributes: record.custom_attributes.merge('medelement_patient_code' => code)) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  it 'reports counts in dry-run mode without writing anything' do
    create(:scheduling_appointment, account: account, contact: owner,
                                    custom_attributes: { policy::OWNED_IDENTITY_KEY => true, 'medelement_patient_code' => 'someone-else' })
    owner_attributes = owner.reload.attributes

    report = described_class.new(account: account).perform

    expect(report).to eq('apply' => false, 'owned_without_card' => 2, 'owner_holds_code' => 1, 'repairable' => 1)
    expect(owner.reload.attributes).to eq(owner_attributes)
    expect(appointment.reload.patient_contact_id).to be_nil
  end

  it 'moves the patient code to a separate card and binds every owned appointment of that patient without merging', :aggregate_failures do
    second = owned_appointment
    contacts_before = account.contacts.count
    commands_before = Integrations::Medelement::ProviderCommand.count

    report = described_class.new(account: account, apply: true).perform

    expect(report).to include('repairable' => 2, 'repaired' => 2)
    card = appointment.reload.patient_contact
    expect(card).to have_attributes(name: 'Relative', last_name: 'Patient', phone_number: nil, identifier: '940720300129')
    expect(card.custom_attributes).to include('medelement_patient_code' => 'relative-2', 'secondary_phones' => [owner.phone_number])
    expect(second.reload.patient_contact_id).to eq(card.id)
    expect(appointment).to have_attributes(contact_id: owner.id, conversation_id: conversation.id)
    expect(owner.reload).to have_attributes(name: 'Primary', phone_number: '+77000000001', identifier: nil)
    expect(owner.custom_attributes).not_to include('medelement_patient_code', 'medelement_first_name', 'medelement_last_synced_at')
    expect(account.contacts.count).to eq(contacts_before + 1)
    expect(Integrations::Medelement::ProviderCommand.count).to eq(commands_before)
    expect(described_class.new(account: account).perform).to include('owned_without_card' => 0)
  end

  it 'locks the appointment rows before the phone identity lock, like the importer and appointment edits' do
    statements = []
    collect = ->(*, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(collect, 'sql.active_record') do
      described_class.new(account: account, apply: true).perform
    end

    appointment_lock = statements.index { |sql| sql.match?(/FROM "scheduling_appointments".*FOR UPDATE/m) }
    phone_lock = statements.index { |sql| sql.include?('pg_advisory_xact_lock') }
    expect(appointment_lock).to be_present
    expect(phone_lock).to be_present
    expect(appointment_lock).to be < phone_lock
  end

  it 'reports a deadlocked group as a failed repair instead of aborting the task' do
    allow(Contacts::PhoneIdentityLock).to receive(:acquire!).and_raise(ActiveRecord::Deadlocked, 'deadlock detected')

    report = described_class.new(account: account, apply: true).perform

    expect(report).to include('repairable' => 1, 'repair_failed' => 1)
    expect(appointment.reload.patient_contact_id).to be_nil
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
  end

  it 'leaves an owner whose identity matches the authored patient for manual review' do
    owner.update!(name: 'Relative', last_name: 'Patient')

    report = described_class.new(account: account, apply: true).perform

    expect(report).to include('skipped_owner_identity_matches' => 1)
    expect(report).not_to have_key('repaired')
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
    expect(appointment.reload.patient_contact_id).to be_nil
  end

  it 'leaves an owner carrying an IIN for manual review' do
    owner.update!(identifier: '940720300119')

    expect(described_class.new(account: account, apply: true).perform).to include('skipped_owner_has_iin' => 1)
    expect(owner.reload.custom_attributes['medelement_patient_code']).to eq('relative-2')
  end

  it 'skips a patient with an unfinished provider command' do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: owner, operation: 'update_patient', status: 'processing',
      company_cabinet_code: 'cabinet-1', provider_patient_code: 'relative-2', idempotency_key: SecureRandom.uuid,
      execution_state: { 'write_phase' => 'patient_write', 'request_snapshot' => {} }
    )

    expect(described_class.new(account: account, apply: true).perform).to include('skipped_unfinished_provider_commands' => 1)
    expect(appointment.reload.patient_contact_id).to be_nil
  end
end
