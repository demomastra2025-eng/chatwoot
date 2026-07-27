require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandConfirmationJob do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) { create(:contact, account: account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:confirmation_request) do
    create(:confirmation_request, account: account, conversation: nil, contact: contact, status: confirmation_status, resolved_at: Time.current)
  end
  let!(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      confirmation_request: confirmation_request,
      operation: 'create_patient',
      status: 'awaiting_confirmation',
      idempotency_key: SecureRandom.uuid
    )
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
