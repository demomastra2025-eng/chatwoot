require 'rails_helper'

RSpec.describe Integrations::Medelement::ProviderCommands::ManualCancellationResolutionService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:actor) { create(:user, :administrator, account: account) }
  let(:contact) { create(:contact, account: account, custom_attributes: { 'medelement_patient_code' => 'patient-1' }) }
  let(:resource) do
    create(:scheduling_resource, account: account, custom_attributes: {
             'medelement_specialist_code' => 'specialist-1',
             'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
           })
  end
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, resource: resource,
                                    custom_attributes: { 'medelement_cabinet_code' => 'cabinet-1' })
  end
  let(:hook) { create(:integrations_hook, :medelement, account: account) }
  let(:reception_code) { 'created-1' }
  let(:client) { instance_double(Integrations::Medelement::Client) }
  let(:command) do
    snapshot = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.new(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: 'create_reception', company_cabinet_code: 'cabinet-1',
      desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at
    ).build
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(snapshot)
    record = Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: 'create_reception', status: 'provider_status_unknown', idempotency_key: SecureRandom.uuid,
      company_cabinet_code: 'cabinet-1', desired_starts_at: appointment.starts_at, desired_ends_at: appointment.ends_at,
      execution_state: {
        'request_snapshot' => snapshot, 'request_fingerprint' => fingerprint,
        'write_phase' => 'reception_create', 'write_provider_patient_code' => 'patient-1',
        'write_provider_reception_code' => reception_code
      }
    )
    confirmation = create(:confirmation_request, account: account, status: 'confirmed', metadata: {
                            'medelement_provider_command_id' => record.id,
                            'operation' => record.operation, 'request_fingerprint' => fingerprint
                          })
    record.update!(confirmation_request: confirmation,
                   execution_state: record.execution_state.merge('confirmation_request_id' => confirmation.id))
    Integrations::Medelement::AppointmentProviderStatus.persist!(
      appointment, Integrations::Medelement::AppointmentProviderStatus::UNKNOWN, command: record
    )
    record
  end
  let(:removed_reception) do
    {
      'RECEPTION_CODE' => reception_code, 'PROFILE_CODE' => 'patient-1',
      'COMPANY_CODE' => command.request_snapshot['organization_id'],
      'SPECIALIST_CODE' => 'specialist-1', 'COMPANY_CABINET_CODE' => 'cabinet-1',
      'STARTTIME' => provider_time(appointment.starts_at), 'ENDTIME' => provider_time(appointment.ends_at),
      'REMOVED' => 1, 'SERVICES' => []
    }
  end

  before do
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
    allow(client).to receive(:get_reception).and_return(removed_reception)
  end

  def provider_time(time)
    time.in_time_zone(command.request_snapshot.dig('reception', 'time_zone')).strftime('%d.%m.%Y %H:%M:%S')
  end

  def perform
    described_class.new(command: command, actor: actor, reception_code: reception_code, client: client).perform
  end

  def expect_unavailable
    expect { perform }.to raise_error(Scheduling::Error) do |error|
      expect(error.code).to eq('MEDELEMENT_CANCELLATION_RESOLUTION_UNAVAILABLE')
    end
    expect(command.reload).not_to be_cancelled
  end

  it 'finishes only the verified original create as cancellation and preserves provider identity' do
    command
    expect do
      perform
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)

    expect(client).to have_received(:get_reception).with(reception_code: reception_code, version: :v2)
    expect(command.reload).to have_attributes(status: 'cancelled', provider_reception_code: reception_code)
    expect(command.execution_state['manual_cancellation_resolution']).to include(
      'result' => 'removed', 'verified_by_id' => actor.id, 'reception_code' => reception_code,
      'request_fingerprint' => command.execution_state['request_fingerprint']
    )
    expect(appointment.reload).to have_attributes(status: 'cancelled', payment_status: 'cancelled',
                                                  external_ref: "medelement:reception:#{reception_code}")
    expect(appointment.custom_attributes['medelement_local_cancelled_at']).to be_present
    expect(Integrations::Medelement::AppointmentProviderStatus.payload(appointment)).not_to include(provider_confirmed: true)
  end

  it 'resolves a retained candidate after historical local cancellation without resurrecting the slot' do
    command.update!(execution_state: command.execution_state.except('write_provider_reception_code').merge(
      'cancelled_reception_candidate_codes' => [reception_code]
    ))
    appointment.update_column(:status, 'cancelled') # rubocop:disable Rails/SkipsModelValidations

    perform

    expect(command.reload).to be_cancelled
    expect(appointment.reload.status).to eq('cancelled')
    guard = Integrations::Medelement::AppointmentSnapshotGuard.new(
      appointment: appointment, snapshot_version: nil, reception_code: reception_code
    )
    expect { guard.validate! }.to raise_error(Integrations::Medelement::AppointmentSnapshotGuard::StaleSnapshotError)
  end

  it 'keeps the first completion and its audit on duplicate clicks' do
    expect(client).to receive(:get_reception).once.and_return(removed_reception)
    perform
    audit = command.reload.execution_state['manual_cancellation_resolution']
    perform

    expect(command.reload.execution_state['manual_cancellation_resolution']).to eq(audit)
  end

  it 'also resolves an unbound employee booking idempotently' do
    command
    attributes = appointment.custom_attributes.except(*Integrations::Medelement::AppointmentProviderStatus::COMMAND_BINDING_KEYS)
    appointment.update_column(:custom_attributes, attributes) # rubocop:disable Rails/SkipsModelValidations
    expect(client).to receive(:get_reception).once.and_return(removed_reception)

    perform
    perform

    expect(Integrations::Medelement::AppointmentProviderStatus.bound_to_command?(appointment.reload, command)).to be(true)
  end

  it 'refuses a repeated resolution after the cancelled target has been changed' do
    perform
    appointment.update_column(:resource_id, create(:scheduling_resource, account: account).id) # rubocop:disable Rails/SkipsModelValidations

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_RESOLUTION_UNAVAILABLE') }
  end

  it 'does not overwrite a concurrent successful manual resolution' do
    second_client = instance_double(Integrations::Medelement::Client, get_reception: removed_reception)
    allow(client).to receive(:get_reception) do
      described_class.new(command: command, actor: actor, reception_code: reception_code, client: second_client).perform
      removed_reception
    end

    perform

    expect(command.reload).to be_cancelled
    expect(command.execution_state['manual_cancellation_resolution']['verified_by_id']).to eq(actor.id)
  end

  {
    'active reception' => { 'REMOVED' => 0 },
    'missing deletion marker' => { 'REMOVED' => nil },
    'fractional deletion marker' => { 'REMOVED' => 1.5 },
    'wrong reception' => { 'RECEPTION_CODE' => 'other' },
    'wrong patient' => { 'PROFILE_CODE' => 'other' },
    'conflicting patient references' => { 'PATIENT_CODE' => 'other' },
    'missing patient' => { 'PROFILE_CODE' => nil },
    'wrong organization' => { 'COMPANY_CODE' => 'other' },
    'missing organization' => { 'COMPANY_CODE' => nil },
    'wrong specialist' => { 'SPECIALIST_CODE' => 'other' },
    'missing specialist' => { 'SPECIALIST_CODE' => nil },
    'wrong cabinet' => { 'COMPANY_CABINET_CODE' => 'other' },
    'missing cabinet' => { 'COMPANY_CABINET_CODE' => nil },
    'wrong start time' => { 'STARTTIME' => '01.01.2000 00:00:00' },
    'wrong end time' => { 'ENDTIME' => '01.01.2000 00:00:00' },
    'wrong service' => { 'SERVICES' => [{ 'NOMENCLATURE_CODE' => 'other', 'REMOVED' => 0 }] },
    'malformed services' => { 'SERVICES' => 'invalid' },
    'unidentified services' => { 'SERVICES' => [{ 'PRICE' => 100 }] }
  }.each do |description, changes|
    it "retains the slot and unresolved command for #{description}" do
      allow(client).to receive(:get_reception).and_return(removed_reception.merge(changes))

      expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_NOT_VERIFIED') }

      expect(command.reload).to be_provider_status_unknown
      expect(appointment.reload.status).not_to eq('cancelled')
    end
  end

  it 'does not treat an empty response as proof of removal' do
    allow(client).to receive(:get_reception).and_return({})

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_NOT_VERIFIED') }
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'requires an explicit services list even for a booking without services' do
    allow(client).to receive(:get_reception).and_return(removed_reception.except('SERVICES'))
    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_NOT_VERIFIED') }
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'keeps the command unresolved when the provider lookup fails' do
    allow(client).to receive(:get_reception).and_raise(Integrations::Medelement::Client::ApiError.new('not found', status: 404))

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_CHECK_FAILED') }
    expect(command.reload).to be_provider_status_unknown
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'refuses an arbitrary ID supplied by the client' do
    expect do
      described_class.new(command: command, actor: actor, reception_code: 'unrelated', client: client).perform
    end.to raise_error(Scheduling::Error)
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses conflicting stored reception references' do
    command.update!(execution_state: command.execution_state.merge('cancelled_reception_candidate_codes' => ['other']))
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses an unknown reception ID before contacting the provider' do
    command.update!(execution_state: command.execution_state.except('write_provider_reception_code'))
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses conflicting stored patient references' do
    command.update!(provider_patient_code: 'other')
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses a command without confirmed consent' do
    command.confirmation_request.update!(status: 'pending')
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses a command whose fingerprint was changed' do
    command.update!(execution_state: command.execution_state.merge('request_fingerprint' => 'invalid'))
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses a changed organization before contacting the provider' do
    command
    hook.update!(settings: hook.settings.merge('organization_id' => 'other'))
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses an employee from another account' do
    outsider = create(:user)
    expect do
      described_class.new(command: command, actor: outsider, reception_code: reception_code, client: client).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.status).to eq(403) }
    expect(client).not_to have_received(:get_reception)
  end

  it 'requires a human account user' do
    expect do
      described_class.new(command: command, actor: nil, reception_code: reception_code, client: client).perform
    end.to raise_error(Scheduling::Error) { |error| expect(error.status).to eq(403) }
  end

  it 'does not modify a newer appointment command binding' do
    command
    appointment.update_column(:custom_attributes, appointment.custom_attributes.merge('medelement_provider_command_id' => command.id + 1)) # rubocop:disable Rails/SkipsModelValidations
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'refuses a partial command binding instead of treating it as unbound' do
    command
    status = Integrations::Medelement::AppointmentProviderStatus
    attributes = appointment.custom_attributes.except(status::COMMAND_ID_KEY).merge(status::COMMAND_FINGERPRINT_KEY => 'other')
    appointment.update_column(:custom_attributes, attributes) # rubocop:disable Rails/SkipsModelValidations
    expect_unavailable
    expect(client).not_to have_received(:get_reception)
  end

  it 'rechecks employee membership after the readback' do
    allow(client).to receive(:get_reception) do
      actor.account_users.find_by!(account: account).destroy!
      removed_reception
    end

    expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.status).to eq(403) }
    expect(command.reload).to be_provider_status_unknown
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'rechecks the organization after the readback' do
    response = removed_reception
    allow(client).to receive(:get_reception) do
      hook.update!(settings: hook.settings.merge('organization_id' => 'other'))
      response
    end

    expect_unavailable
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'rechecks the current specialist mapping after the readback' do
    response = removed_reception
    allow(client).to receive(:get_reception) do
      resource.update!(custom_attributes: resource.custom_attributes.merge('medelement_specialist_code' => 'other'))
      response
    end

    expect_unavailable
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'rechecks the current patient mapping after the readback' do
    response = removed_reception
    allow(client).to receive(:get_reception) do
      contact.update!(custom_attributes: contact.custom_attributes.merge('medelement_patient_code' => 'other'))
      response
    end

    expect_unavailable
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  it 'retains a booking edited while the provider check is in flight' do
    original_end = appointment.ends_at
    allow(client).to receive(:get_reception) do
      appointment.update_column(:ends_at, original_end + 10.minutes) # rubocop:disable Rails/SkipsModelValidations
      removed_reception.merge('ENDTIME' => provider_time(original_end))
    end

    expect_unavailable
    expect(appointment.reload.ends_at).to eq(original_end + 10.minutes)
    expect(appointment.status).not_to eq('cancelled')
  end

  it 'does not steal a reconciliation claim taken while the check is in flight' do
    allow(client).to receive(:get_reception) do
      command.update!(status: 'processing', execution_state: command.execution_state.merge('reconciliation_claim_token' => 'new-owner'))
      removed_reception
    end

    expect_unavailable
    expect(command.reload.execution_state['reconciliation_claim_token']).to eq('new-owner')
    expect(appointment.reload.status).not_to eq('cancelled')
  end

  context 'with a mapped service' do
    let(:appointment) do
      super().tap do |record|
        record.update!(service: create(:scheduling_service, account: account,
                                                            custom_attributes: { 'medelement_nomenclature_code' => 'service-1' }))
      end
    end
    let(:removed_reception) { super().merge('SERVICES' => [{ 'NOMENCLATURE_CODE' => 'service-1' }]) }

    it 'resolves only when the exact requested service is also proven' do
      perform
      expect(command.reload).to be_cancelled
    end

    it 'supports a CREATE whose service is kept locally with an explicit empty provider services list' do
      allow(client).to receive(:get_reception).and_return(removed_reception.merge('SERVICES' => []))

      perform
      expect(command.reload).to be_cancelled
      expect(appointment.reload.status).to eq('cancelled')
    end

    it 'still refuses a missing provider services field for a locally retained service' do
      allow(client).to receive(:get_reception).and_return(removed_reception.except('SERVICES'))

      expect { perform }.to raise_error(Scheduling::Error) { |error| expect(error.code).to eq('MEDELEMENT_CANCELLATION_NOT_VERIFIED') }
      expect(appointment.reload.status).not_to eq('cancelled')
    end
  end

  context 'with the account scoped API', type: :request do
    let(:headers) { actor.create_new_auth_token }
    let(:path) { "/api/v1/accounts/#{account.id}/scheduling/provider_commands/#{command.id}/resolve_cancellation" }

    before { allow(Integrations::Medelement::Client).to receive(:new).and_return(client) }

    it 'returns the cancelled command and appointment without enqueuing a provider write' do
      command
      expect do
        post path, params: { provider: 'medelement', reception_code: reception_code }, headers: headers, as: :json
      end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)

      expect(response).to have_http_status(:ok)
      payload = response.parsed_body['payload']
      expect(payload).to include('id' => command.id, 'status' => 'cancelled')
      expect(payload['appointment']).to include('id' => appointment.id, 'status' => 'cancelled')
      expect(payload['manual_cancellation_resolution']).to include('result' => 'removed', 'verified_by_id' => actor.id)
    end

    it 'does not allow another account to resolve this command' do
      foreign_account = create(:account).tap { |record| record.enable_features!('scheduling') }
      outsider = create(:user, :administrator, account: foreign_account)
      foreign_path = "/api/v1/accounts/#{foreign_account.id}/scheduling/provider_commands/#{command.id}/resolve_cancellation"

      post foreign_path, params: { provider: 'medelement', reception_code: reception_code }, headers: outsider.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(command.reload).to be_provider_status_unknown
      expect(client).not_to have_received(:get_reception)
    end

    it 'returns a conflict and preserves the booking when removal is unverified' do
      allow(client).to receive(:get_reception).and_return(removed_reception.merge('REMOVED' => 0))

      post path, params: { provider: 'medelement', reception_code: reception_code }, headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('MEDELEMENT_CANCELLATION_NOT_VERIFIED')
      expect(appointment.reload.status).not_to eq('cancelled')
    end

    it 'protects a historically cancelled appointment with an unresolved CREATE from deletion' do
      command
      appointment.update_column(:status, 'cancelled') # rubocop:disable Rails/SkipsModelValidations

      delete "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}", headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('MEDELEMENT_CANCELLATION_RECORD_PROTECTED')
      expect(Scheduling::Appointment.exists?(appointment.id)).to be(true)
    end

    it 'retains the verified cancellation record and audit for synchronization' do
      perform

      delete "/api/v1/accounts/#{account.id}/scheduling/appointments/#{appointment.id}", headers: headers, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('MEDELEMENT_CANCELLATION_RECORD_PROTECTED')
      expect(Scheduling::Appointment.exists?(appointment.id)).to be(true)
      expect(command.reload.execution_state['manual_cancellation_resolution']).to include('result' => 'removed')
    end
  end
end
