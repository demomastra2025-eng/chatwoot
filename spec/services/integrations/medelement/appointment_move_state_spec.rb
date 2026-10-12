require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentMoveState do
  let(:status) { Integrations::Medelement::AppointmentProviderStatus }
  let(:confirmed) { { starts_at: Time.utc(2026, 10, 15, 5, 0), ends_at: Time.utc(2026, 10, 15, 5, 30), duration_min: 30 } }
  let(:requested) { { starts_at: Time.utc(2026, 10, 14, 5, 30), ends_at: Time.utc(2026, 10, 14, 6, 0), duration_min: 30 } }
  let(:command) do
    instance_double(
      Integrations::Medelement::ProviderCommand,
      id: 160, created_at: Time.utc(2026, 10, 12, 19, 0), last_error_code: nil, last_error_status: nil,
      request_snapshot: {
        'reception' => {
          'source_starts_at' => '2026-10-15T05:00:00.000000Z', 'source_ends_at' => '2026-10-15T05:30:00.000000Z',
          'destination_starts_at' => '2026-10-14T05:30:00.000000Z', 'destination_ends_at' => '2026-10-14T06:00:00.000000Z'
        }
      },
      execution_state: {
        'write_phase' => 'reception_move',
        'write_failure' => { 'code' => 'provider_http_error', 'status' => 400 }
      }
    )
  end

  it 'records the confirmed and the requested interval when a move is staged' do
    attributes = described_class.staged({ 'keep' => 1 }, confirmed: confirmed, requested: requested)

    expect(attributes).to include('keep' => 1)
    expect(attributes[described_class::ATTRIBUTE_KEY]).to include(
      'state' => 'pending',
      'confirmed_starts_at' => '2026-10-15T05:00:00.000000Z', 'confirmed_ends_at' => '2026-10-15T05:30:00.000000Z',
      'requested_starts_at' => '2026-10-14T05:30:00.000000Z', 'requested_ends_at' => '2026-10-14T06:00:00.000000Z'
    )
    expect(described_class.open?(attributes)).to be(true)
  end

  it 'derives the state from the provider status projected for the command' do
    base = { status::ATTRIBUTE_KEY => status::UNKNOWN }

    unknown = described_class.projected(base, command: command, provider_status: status::UNKNOWN)
    expect(unknown[described_class::ATTRIBUTE_KEY]).to include(
      'state' => 'needs_reconciliation', 'command_id' => 160, 'error_code' => 'provider_http_error', 'error_status' => 400,
      'confirmed_starts_at' => '2026-10-15T05:00:00.000000Z', 'requested_starts_at' => '2026-10-14T05:30:00.000000Z'
    )
    expect(unknown[described_class::ATTRIBUTE_KEY]).not_to have_key('evidence')

    rejected = described_class.projected(unknown, command: command, provider_status: status::FAILED)
    expect(rejected[described_class::ATTRIBUTE_KEY]).to include('state' => 'rejected', 'evidence' => 'provider_rejected')
    expect(described_class.rejected?(rejected)).to be(true)
    expect(described_class.open?(rejected)).to be(false)
  end

  it 'reports a rejection of a request that was never sent as not sent' do
    allow(command).to receive(:execution_state).and_return({})

    rejected = described_class.projected({}, command: command, provider_status: status::FAILED)

    expect(rejected[described_class::ATTRIBUTE_KEY]).to include('state' => 'rejected', 'evidence' => 'not_sent')
  end

  it 'keeps the original request time across projections and drops the state once the provider confirms the move' do
    pending = described_class.projected({}, command: command, provider_status: status::PENDING)
    again = described_class.projected(pending, command: command, provider_status: status::UNKNOWN)

    expect(again[described_class::ATTRIBUTE_KEY]['requested_at']).to eq(pending[described_class::ATTRIBUTE_KEY]['requested_at'])
    expect(described_class.projected(again, command: command, provider_status: status::SUCCEEDED)).not_to have_key(described_class::ATTRIBUTE_KEY)
  end

  it 'flags a waiting request when the write result is unresolved without a command' do
    staged = described_class.staged({}, confirmed: confirmed, requested: requested)
    rejected = { described_class::ATTRIBUTE_KEY => { 'state' => 'rejected' } }

    expect(described_class.flagged(staged)[described_class::ATTRIBUTE_KEY]).to include('state' => 'needs_reconciliation')
    expect(described_class.flagged(rejected)).to eq(rejected)
    expect(described_class.flagged({})).to eq({})
  end

  it 'exposes a payload that never presents the requested time as confirmed' do
    appointment = build_stubbed(:scheduling_appointment)
    appointment.custom_attributes = described_class.projected({}, command: command, provider_status: status::UNKNOWN)

    payload = described_class.payload(appointment)[:provider_move]

    expect(payload).to include(
      state: 'needs_reconciliation', requested_time_confirmed: false, needs_reconciliation: true, command_id: 160,
      confirmed_starts_at: '2026-10-15T05:00:00.000000Z', requested_starts_at: '2026-10-14T05:30:00.000000Z',
      error_code: 'provider_http_error', error_status: 400
    )
    expect(described_class.payload(build_stubbed(:scheduling_appointment))).to eq({})
  end

  it 'maps a move state back to the provider sync status it stands for' do
    expect(described_class.provider_status_for('pending')).to eq(status::PENDING)
    expect(described_class.provider_status_for('needs_reconciliation')).to eq(status::UNKNOWN)
    expect(described_class.provider_status_for('rejected')).to eq(status::FAILED)
    expect(described_class.provider_status_for(nil)).to be_nil
  end

  describe '.after_provider_import' do
    let(:rejected) do
      described_class.projected({ 'keep' => 1 }, command: command, provider_status: status::FAILED)
    end

    it 'keeps a rejection while the provider shows the interval the move kept' do
      expect(described_class.after_provider_import(rejected, starts_at: confirmed[:starts_at], ends_at: confirmed[:ends_at])).to eq(rejected)
    end

    it 'drops a rejection once the provider shows another interval' do
      result = described_class.after_provider_import(rejected, starts_at: requested[:starts_at], ends_at: requested[:ends_at])

      expect(result).to eq('keep' => 1)
    end

    it 'never drops a request that is still open' do
      open = described_class.staged({}, confirmed: confirmed, requested: requested)

      expect(described_class.after_provider_import(open, starts_at: requested[:starts_at], ends_at: requested[:ends_at])).to eq(open)
      expect(described_class.after_provider_import({ 'keep' => 1 }, starts_at: nil, ends_at: nil)).to eq('keep' => 1)
    end
  end

  it 'ignores unknown states and unparsable times' do
    expect(described_class.read('medelement_move_request' => { 'state' => 'applied' })).to be_nil
    expect(described_class.time({ 'requested_starts_at' => 'not a time' }, 'requested_starts_at')).to be_nil
    expect(described_class.time(nil, 'requested_starts_at')).to be_nil
  end
end
