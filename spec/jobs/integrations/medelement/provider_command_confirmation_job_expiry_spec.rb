require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommandConfirmationJob do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:contact) { create(:contact, account: account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:confirmation_request) do
    create(
      :confirmation_request,
      account: account,
      conversation: nil,
      contact: contact,
      status: 'pending',
      expires_at: 1.minute.ago
    )
  end
  let!(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      confirmation_request: confirmation_request,
      operation: 'create_patient',
      status: 'awaiting_confirmation',
      idempotency_key: 'expired-confirmation-command'
    )
  end

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(Integrations::Medelement::ProviderCommandJob).to receive(:perform_later)
    allow(described_class).to receive(:perform_later).and_call_original
  end

  it 'is recovered by the dispatcher and transitions to a declined command' do
    Integrations::Medelement::ProviderCommandDispatcherJob.perform_now

    expect(described_class)
      .to have_received(:perform_later).with(confirmation_request.id)

    described_class.perform_now(confirmation_request.id)

    expect(confirmation_request.reload).to be_expired
    expect(command.reload).to be_declined
    expect(Integrations::Medelement::ProviderCommandJob).not_to have_received(:perform_later)
  end
end
