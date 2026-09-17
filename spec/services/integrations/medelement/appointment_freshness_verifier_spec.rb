require 'rails_helper'

RSpec.describe Integrations::Medelement::AppointmentFreshnessVerifier do
  let(:account) { create(:account) }
  let(:resource) do
    create(
      :scheduling_resource,
      account: account,
      timezone: 'Asia/Almaty',
      custom_attributes: { 'medelement_specialist_code' => 'specialist-1' }
    )
  end
  let(:starts_at) { Time.zone.parse('2026-09-07 09:00:00 +0500') }
  let(:appointment) do
    create(
      :scheduling_appointment,
      account: account,
      resource: resource,
      starts_at: starts_at,
      ends_at: starts_at + 30.minutes,
      external_ref: 'medelement:reception:reception-1',
      custom_attributes: { 'medelement_reception_code' => 'reception-1' }
    )
  end
  let(:client) { instance_double(Integrations::Medelement::Client) }

  before do
    account.enable_features!('scheduling')
    create(:integrations_hook, :medelement, account: account)
  end

  it 'allows delivery only when the provider reception is active and time-current' do
    allow(client).to receive(:get_reception).and_return(
      'RECEPTION_CODE' => 'reception-1',
      'SPECIALIST_CODE' => 'specialist-1',
      'STARTTIME' => '07.09.2026 09:00:00',
      'ENDTIME' => '07.09.2026 09:30:00',
      'REMOVED' => 0
    )

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'fresh', reason: nil)
    expect(result).to be_allowed
  end

  it 'blocks a provider response for a different reception' do
    allow(client).to receive(:get_reception).and_return(
      'RECEPTION_CODE' => 'reception-2',
      'SPECIALIST_CODE' => 'specialist-1',
      'STARTTIME' => '07.09.2026 09:00:00',
      'ENDTIME' => '07.09.2026 09:30:00',
      'REMOVED' => 0
    )

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'blocked', reason: 'provider_reception_mismatch')
  end

  it 'blocks a provider response with a malformed removal state' do
    allow(client).to receive(:get_reception).and_return(
      'RECEPTION_CODE' => 'reception-1',
      'SPECIALIST_CODE' => 'specialist-1',
      'STARTTIME' => '07.09.2026 09:00:00',
      'ENDTIME' => '07.09.2026 09:30:00',
      'REMOVED' => 'garbage'
    )

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'blocked', reason: 'provider_response_invalid')
  end

  it 'blocks a time-shifted provider reception' do
    allow(client).to receive(:get_reception).and_return(
      'RECEPTION_CODE' => 'reception-1',
      'SPECIALIST_CODE' => 'specialist-1',
      'STARTTIME' => '07.09.2026 10:00:00',
      'ENDTIME' => '07.09.2026 10:30:00',
      'REMOVED' => 0
    )

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'blocked', reason: 'provider_reception_time_changed')
    expect(result).not_to be_allowed
  end

  it 'blocks an active provider reception with missing specialist identity' do
    allow(client).to receive(:get_reception).and_return(
      'RECEPTION_CODE' => 'reception-1',
      'STARTTIME' => '07.09.2026 09:00:00',
      'ENDTIME' => '07.09.2026 09:30:00',
      'REMOVED' => 0
    )

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'blocked', reason: 'provider_reception_specialist_changed')
  end

  it 'stops a locally cancelled appointment without reading the provider' do
    appointment.update!(status: 'cancelled')
    allow(client).to receive(:get_reception)

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'cancelled', reason: 'local_appointment_cancelled')
    expect(client).not_to have_received(:get_reception)
  end

  it 'marks a removed provider reception as terminally cancelled' do
    allow(client).to receive(:get_reception).and_return(
      'RECEPTION_CODE' => 'reception-1',
      'STARTTIME' => '07.09.2026 09:00:00',
      'ENDTIME' => '07.09.2026 09:30:00',
      'REMOVED' => 1
    )

    result = described_class.new(appointment: appointment, client: client).perform

    expect(result).to have_attributes(status: 'cancelled', reason: 'provider_reception_cancelled')
    expect(result).to be_terminal
  end

  it 'blocks while the operation-specific provider command is unfinished without calling the provider' do
    command = instance_double(
      Integrations::Medelement::ProviderCommand,
      id: 123,
      status: 'provider_status_unknown'
    )
    verifier = described_class.new(appointment: appointment, client: client)
    allow(verifier).to receive(:latest_command).and_return(command)
    allow(client).to receive(:get_reception)

    result = verifier.perform

    expect(result).to have_attributes(
      status: 'blocked',
      reason: 'provider_command_provider_status_unknown',
      command_id: 123,
      command_status: 'provider_status_unknown'
    )
    expect(client).not_to have_received(:get_reception)
  end
end
