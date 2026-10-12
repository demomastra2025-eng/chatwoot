require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandReconciliationJob do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
  let(:status) { 'reconciliation_required' }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: 'create_reception', status: status,
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1', provider_patient_code: 'patient-1',
      provider_reception_code: 'reception-1', desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      execution_state: { 'write_phase' => 'reception_create', 'write_provider_reception_code' => 'reception-1' }
    )
  end
  let(:job) { described_class.new }
  let(:reconciliation) { instance_double(Integrations::Medelement::ProviderCommands::ReconciliationService, perform: nil) }
  let(:verification) { instance_double(Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService, perform: nil) }

  before do
    allow(job).to receive(:with_lock).and_yield
    allow(Integrations::Medelement::ProviderCommands::ReconciliationService).to receive(:new).and_return(reconciliation)
    allow(Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService).to receive(:new).and_return(verification)
  end

  context 'when the command is waiting for a reconciliation read' do
    it 'reconciles it under the contact and resource locks of real commands' do
      job.perform(command.id)

      expect(job).to have_received(:with_lock).twice
      expect(reconciliation).to have_received(:perform)
      expect(verification).not_to have_received(:perform)
    end
  end

  context 'when the command is an accepted create whose receipt is only being checked' do
    let(:status) { 'succeeded' }

    it 'checks the receipt without taking the locks, so a slow provider cannot hold them while the next booking waits' do
      expect(Integrations::Medelement::ProviderCommands::ReceptionReceiptVerificationService).to be_applicable(command)

      job.perform(command.id)

      expect(job).not_to have_received(:with_lock)
      expect(verification).to have_received(:perform)
      expect(reconciliation).not_to have_received(:perform)
    end
  end

  it 'ignores a command that is gone' do
    job.perform(0)

    expect(job).not_to have_received(:with_lock)
  end
end
