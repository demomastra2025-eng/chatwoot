require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandConfirmationJob do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) { create(:contact, account: account, phone_number: '+77010000000') }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:confirmation_request) do
    create(:confirmation_request, account: account, conversation: nil, contact: contact, status: confirmation_status, resolved_at: Time.current)
  end
  let(:command_status) { 'awaiting_confirmation' }
  let!(:command) do
    request_snapshot = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient'
    ).build
    request_fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(request_snapshot)
    record = Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      confirmation_request: confirmation_request,
      operation: 'create_patient',
      status: command_status,
      idempotency_key: SecureRandom.uuid,
      execution_state: {
        'request_snapshot' => request_snapshot,
        'request_fingerprint' => request_fingerprint,
        'confirmation_request_id' => confirmation_request.id
      }
    )
    confirmation_request.update!(
      metadata: {
        'medelement_provider_command_id' => record.id,
        'operation' => record.operation,
        'request_fingerprint' => request_fingerprint
      }
    )
    record
  end

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later)
  end

  context 'when the request is confirmed' do
    let(:confirmation_status) { 'confirmed' }

    it 'queues the command and its executor' do
      described_class.perform_now(confirmation_request.id)

      expect(command.reload).to be_queued
      expect(command.confirmed_at).to eq(confirmation_request.resolved_at)
      expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(command.id)
    end

    context 'with a versioned command' do
      let(:command_status) { 'v2_awaiting_confirmation' }

      it 'preserves the versioned status through confirmation' do
        described_class.perform_now(confirmation_request.id)

        expect(command.reload).to have_attributes(status: 'v2_queued', logical_status: 'queued')
        expect(Integrations::Medelement::ProviderCommandJob).to have_received(:perform_later).with(command.id)
      end
    end

    {
      'medelement_provider_command_id' => -1,
      'operation' => 'update_patient',
      'request_fingerprint' => 'tampered'
    }.each do |field, invalid_value|
      it "fails closed when confirmation #{field} does not match" do
        confirmation_request.update!(metadata: confirmation_request.metadata.merge(field => invalid_value))

        described_class.perform_now(confirmation_request.id)

        expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'confirmation_snapshot_invalid')
        expect(Integrations::Medelement::ProviderCommandJob).not_to have_received(:perform_later)
      end
    end

    it 'fails closed when another confirmed request is linked to the command' do
      replacement = create(
        :confirmation_request,
        account: account,
        conversation: nil,
        contact: contact,
        status: 'confirmed',
        resolved_at: Time.current,
        metadata: confirmation_request.metadata
      )
      command.update_column(:confirmation_request_id, replacement.id) # rubocop:disable Rails/SkipsModelValidations

      described_class.perform_now(replacement.id)

      expect(command.reload).to have_attributes(status: 'failed', last_error_code: 'confirmation_snapshot_invalid')
      expect(Integrations::Medelement::ProviderCommandJob).not_to have_received(:perform_later)
    end
  end

  context 'when the request is declined' do
    let(:confirmation_status) { 'declined' }

    it 'declines the command without queueing an executor' do
      described_class.perform_now(confirmation_request.id)

      expect(command.reload).to be_declined
      expect(Integrations::Medelement::ProviderCommandJob).not_to have_received(:perform_later)
    end
  end
end
