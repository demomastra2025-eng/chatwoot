require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::UnstartedWithdrawal do
  subject(:withdrawal) { described_class.new(command: command) }

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
  let(:status) { 'queued' }
  let(:operation) { 'move_reception' }
  let(:execution_state) { {} }
  let(:confirmation_request) { nil }
  # A move or removal carries the code of the reception it is about from the start; that is not a write result.
  let(:provider_reception_code) { operation == 'create_reception' ? nil : 'reception-1' }
  let(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      account: account, appointment: appointment, contact: contact, operation: operation, status: status,
      idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1', confirmation_request: confirmation_request,
      provider_reception_code: provider_reception_code,
      desired_starts_at: appointment.starts_at + 1.day, desired_ends_at: appointment.ends_at + 1.day, execution_state: execution_state
    )
  end

  %w[queued v2_queued awaiting_confirmation].each do |waiting_status|
    context "when the command is #{waiting_status} and nothing was sent" do
      let(:status) { waiting_status }

      it 'cancels it with the reason, so the queue can no longer book, move or cancel behind the human who took over' do
        expect(withdrawal.perform).to be(true)

        expect(command.reload).to have_attributes(status: 'cancelled', last_error_code: 'agent_wait_timeout')
        expect(command.executed_at).to be_present
      end
    end
  end

  it 'marks the move request on the appointment as not sent, so the calendar shows it red' do
    withdrawal.perform

    expect(appointment.reload.custom_attributes['medelement_move_request']).to include(
      'state' => 'rejected', 'evidence' => 'not_sent', 'error_code' => 'agent_wait_timeout', 'command_id' => command.id
    )
  end

  context 'when the command is a booking' do
    let(:operation) { 'create_reception' }

    it 'marks the booking failed' do
      appointment.update!(
        custom_attributes: appointment.custom_attributes.merge(Integrations::Medelement::AppointmentProviderStatus.command_attributes(command))
      )
      command.update!(execution_state: { 'request_snapshot' => { 'actor' => { 'type' => 'Captain::Assistant', 'id' => 1 } } })

      withdrawal.perform

      expect(appointment.reload.custom_attributes[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY])
        .to eq(Integrations::Medelement::AppointmentProviderStatus::FAILED)
    end
  end

  context 'when the command waits for a confirmation' do
    let(:status) { 'awaiting_confirmation' }
    let(:confirmation_request) do
      create(:confirmation_request, account: account, conversation: nil, contact: contact, status: 'pending')
    end

    it 'expires the pending confirmation too' do
      withdrawal.perform

      expect(confirmation_request.reload).to have_attributes(status: 'expired', resolution_source: 'system')
      expect(confirmation_request.resolution_metadata).to include('reason' => 'agent_wait_timeout')
    end

    it 'is not started later by the confirmation job' do
      withdrawal.perform

      expect do
        Integrations::Medelement::ProviderCommandConfirmationJob.perform_now(confirmation_request.id)
      end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)
      expect(command.reload).to be_cancelled
    end
  end

  %w[processing reconciliation_required provider_status_unknown succeeded failed cancelled declined].each do |other_status|
    context "when the command is already #{other_status}" do
      let(:status) { other_status }

      it 'leaves it alone' do
        expect(withdrawal.perform).to be(false)

        expect(command.reload.status).to eq(other_status)
        expect(command.last_error_code).to be_nil
      end
    end
  end

  context 'when a write phase or a provider reference is already recorded' do
    it 'leaves a queued command alone: its result is unknown, not absent' do
      command.update!(execution_state: { 'write_phase' => 'reception_move' })

      expect(withdrawal.perform).to be(false)
      expect(command.reload).to be_queued
    end

    it 'leaves a command with a written reception reference alone' do
      command.update!(execution_state: { 'write_provider_reception_code' => 'reception-1' })

      expect(withdrawal.perform).to be(false)
      expect(command.reload).to be_queued
    end
  end

  it 'does not withdraw a command that the executor claimed in the meantime' do
    stale_copy = Integrations::Medelement::ProviderCommand.find(command.id)
    command.update!(status: 'processing')

    expect(stale_copy).to be_queued
    expect(described_class.new(command: stale_copy).perform).to be(false)
    expect(command.reload).to be_processing
  end

  it 'is not claimed by the executor once withdrawn' do
    withdrawal.perform

    executor = Integrations::Medelement::ProviderCommands::Executor.new(command: command.reload)
    expect(executor).not_to receive(:execute_operation!)

    executor.perform

    expect(command.reload).to be_cancelled
  end
end
