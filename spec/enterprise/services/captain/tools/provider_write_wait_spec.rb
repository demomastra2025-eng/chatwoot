require 'rails_helper'

RSpec.describe Captain::Tools::ProviderWriteWait do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:resource) { create(:scheduling_resource, account: account) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact, resource: resource) }
  let(:command_status) { 'queued' }
  let(:command_attributes) { {} }
  let!(:command) do
    Integrations::Medelement::ProviderCommand.create!(
      {
        account: account, appointment: appointment, contact: contact, operation: 'move_reception', status: command_status,
        idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1',
        desired_starts_at: appointment.starts_at + 1.day, desired_ends_at: appointment.ends_at + 1.day
      }.merge(command_attributes)
    )
  end
  let(:now) { [0.0] }
  let(:sleeps) { [] }
  let(:clock) { -> { now.first } }
  let(:sleeper) do
    lambda do |seconds|
      sleeps << seconds
      now[0] += seconds
      yield_step&.call(sleeps.size)
    end
  end
  let(:yield_step) { nil }

  def wait(timeout: 1.0)
    described_class.new(command: command, timeout: timeout, poll: 0.25, sleeper: sleeper, clock: clock).perform
  end

  it 'returns the command at once when MedElement already answered OK' do
    command.update!(status: 'succeeded')

    expect(wait).to eq(command)
    expect(sleeps).to be_empty
  end

  context 'when the answer arrives while waiting' do
    let(:yield_step) { ->(poll) { command.update!(status: 'succeeded') if poll == 2 } }

    it 'polls until MedElement answered OK and then reports success' do
      expect(wait(timeout: 5)).to eq(command)
      expect(sleeps).to eq([0.25, 0.25])
    end
  end

  {
    'slot_conflict' => 'SLOT_CONFLICT',
    'slot_unavailable' => 'APPOINTMENT_SLOT_UNAVAILABLE'
  }.each do |last_error_code, error_code|
    context "when the command failed with #{last_error_code}" do
      let(:command_status) { 'failed' }
      let(:command_attributes) { { last_error_code: last_error_code } }

      it 'raises a business error the agent can act on' do
        expect { wait }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq(error_code) }
      end
    end
  end

  %w[provider_http_error executor_error appointment_superseded patient_not_found].each do |last_error_code|
    context "when the command failed with #{last_error_code}" do
      let(:command_status) { 'failed' }
      let(:command_attributes) { { last_error_code: last_error_code, last_error_status: 422 } }

      it 'raises a technical error' do
        expect { wait }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_WRITE_FAILED') }
      end
    end
  end

  %w[declined cancelled awaiting_patient_selection awaiting_patient_creation awaiting_phone_refresh].each do |status|
    context "when the command ended #{status}" do
      let(:command_status) { status }

      it 'raises a technical error' do
        expect { wait }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_WRITE_FAILED') }
      end
    end
  end

  %w[reconciliation_required provider_status_unknown v2_reconciliation_required].each do |status|
    context "when the answer is ambiguous (#{status})" do
      let(:command_status) { status }

      it 'raises a technical unknown-result error without waiting for the timeout' do
        expect { wait }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_WRITE_UNKNOWN') }
        expect(sleeps).to be_empty
      end
    end
  end

  it 'raises a technical timeout error when MedElement does not answer in time' do
    expect { wait(timeout: 1.0) }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_WRITE_TIMEOUT') }
    expect(sleeps).to eq([0.25, 0.25, 0.25, 0.25])
  end

  describe '.timeout_seconds' do
    around do |example|
      original = ENV.fetch(described_class::TIMEOUT_ENV_KEY, nil)
      example.run
    ensure
      ENV[described_class::TIMEOUT_ENV_KEY] = original
    end

    it 'defaults to 20 seconds' do
      ENV.delete(described_class::TIMEOUT_ENV_KEY)

      expect(described_class.timeout_seconds).to eq(20)
    end

    it 'can be configured' do
      ENV[described_class::TIMEOUT_ENV_KEY] = '7.5'

      expect(described_class.timeout_seconds).to eq(7.5)
    end

    %w[0 -3 soon].each do |invalid|
      it "ignores the invalid value #{invalid.inspect}" do
        ENV[described_class::TIMEOUT_ENV_KEY] = invalid

        expect(described_class.timeout_seconds).to eq(20)
      end
    end
  end
end
