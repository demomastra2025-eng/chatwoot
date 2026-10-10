require 'rails_helper'

RSpec.describe 'Medelement Provider Commands API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, name: 'Ivanov Ivan', phone_number: '+77001234567') }
  let(:hook_settings) { attributes_for(:integrations_hook, :medelement)[:settings].merge('write_enabled' => true) }
  let(:hook) { create(:integrations_hook, :medelement, account: account, settings: hook_settings, status: :enabled) }
  let(:path) { "/api/v1/accounts/#{account.id}/scheduling/provider_commands" }
  let(:headers) { agent.create_new_auth_token }

  before do
    account.enable_features!('scheduling')
    schedule_service = instance_double(Integrations::Medelement::CronScheduleService, sync!: true)
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_return(schedule_service)
  end

  context 'when staging a manual reception move' do
    let(:resource) do
      create(:scheduling_resource, account: account, custom_attributes: {
        'medelement_specialist_code' => 'specialist-1',
        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
      })
    end
    let(:appointment) do
      create(:scheduling_appointment, account: account, resource: resource, contact: contact, source: 'medelement',
                                      external_ref: 'medelement:reception:71')
    end
    let(:destination_start) { Time.current.change(sec: 0) + 1.day }

    before do
      contact.update!(custom_attributes: contact.custom_attributes.merge('medelement_patient_code' => 'patient-1'))
      expect(Integrations::Medelement::Client).not_to receive(:new)
    end

    def stage_move(duration_seconds)
      post path, params: {
        hook_id: hook.id, appointment_id: appointment.id, operation: 'move_reception',
        idempotency_key: SecureRandom.uuid, company_cabinet_code: 'cabinet-1',
        desired_starts_at: destination_start.iso8601(6),
        desired_ends_at: (destination_start + duration_seconds).iso8601(6)
      }, headers: headers, as: :json
    end

    [60, 1441 * 60, 330, 300.1].each do |seconds|
      it "rejects #{seconds} seconds before staging a command or confirmation" do
        appointment
        hook

        expect { stage_move(seconds) }.to(
          not_change(Integrations::Medelement::ProviderCommand, :count).and(not_change(ConfirmationRequest, :count))
        )

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['code']).to eq('INVALID_DURATION')
      end
    end

    [5, 1440].each do |minutes|
      it "stages exactly #{minutes} minutes without changing the requested interval" do
        stage_move(minutes * 60)

        expect(response).to have_http_status(:created)
        expect(Integrations::Medelement::ProviderCommand.last).to have_attributes(
          desired_starts_at: destination_start, desired_ends_at: destination_start + minutes.minutes
        )
      end
    end

    context 'when the authorized staff destination is in the past' do
      let(:destination_start) { Time.current.change(sec: 0) - 1.day }

      it 'preserves the existing retrospective staging behavior' do
        stage_move(5 * 60)

        expect(response).to have_http_status(:created)
        expect(Integrations::Medelement::ProviderCommand.last.desired_starts_at).to eq(destination_start)
      end
    end
  end

  it 'creates only an awaiting-confirmation proposal' do
    post path,
         params: {
           hook_id: hook.id,
           contact_id: contact.id,
           operation: 'create_patient',
           idempotency_key: 'patient-proposal-1'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig('payload', 'status')).to eq('awaiting_confirmation')
    expect(response.parsed_body.dig('payload', 'confirmation', 'status')).to eq('pending')
    expect(response.parsed_body.dig('payload', 'confirmation')).not_to have_key('token')
    expect(Integrations::Medelement::ProviderCommand.last).to have_attributes(contact: contact, attempt_count: 0)
  end

  it 'resolves the active Medelement hook when hook_id is omitted' do
    hook

    expect do
      post path,
           params: {
             contact_id: contact.id,
             operation: 'create_patient',
             idempotency_key: 'patient-proposal-default-hook'
           },
           headers: headers,
           as: :json
    end.to change(Integrations::Medelement::ProviderCommand, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(Integrations::Medelement::ProviderCommand.last.hook).to eq(hook)
  end

  it 'fails closed when write capability is disabled' do
    hook.update!(settings: hook.settings.merge('write_enabled' => false))

    post path,
         params: {
           hook_id: hook.id,
           contact_id: contact.id,
           operation: 'create_patient',
           idempotency_key: 'patient-proposal-disabled'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['code']).to eq('MEDELEMENT_WRITE_DISABLED')
  end

  it 'rejects direct reception create for an already-linked same-account appointment' do
    resource = create(:scheduling_resource, account: account, custom_attributes: {
                        'medelement_specialist_code' => 'specialist-1',
                        'medelement_cabinets' => [{ 'companyCabinetCode' => 'cabinet-1' }]
                      })
    appointment = create(:scheduling_appointment,
                         account: account, contact: contact, resource: resource,
                         external_ref: 'medelement:reception:71')

    expect do
      post path,
           params: {
             hook_id: hook.id, appointment_id: appointment.id, operation: 'create_reception',
             idempotency_key: 'duplicate-linked-reception', company_cabinet_code: 'cabinet-1'
           }, headers: headers, as: :json
    end.not_to change(Integrations::Medelement::ProviderCommand, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('MEDELEMENT_RECEPTION_ALREADY_LINKED')
  end

  it 'does not resolve a hook from another account' do
    other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
    other_hook = create(:integrations_hook, :medelement, account: other_account)

    post path,
         params: {
           hook_id: other_hook.id,
           contact_id: contact.id,
           operation: 'create_patient',
           idempotency_key: 'cross-account-hook'
         },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'lists only commands from the current account' do
    own_command = create_command(account: account, hook: hook, contact: contact)
    other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
    other_contact = create(:contact, account: other_account)
    other_hook = create(:integrations_hook, :medelement, account: other_account)
    create_command(account: other_account, hook: other_hook, contact: other_contact)

    get path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload').pluck('id')).to eq([own_command.id])
  end

  it 'confirms an awaiting command as the authenticated user' do
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      idempotency_key: 'dashboard-confirm-command',
      actor: agent
    ).perform

    expect do
      post "#{path}/#{command.id}/confirm", headers: headers, as: :json
    end.to have_enqueued_job(Integrations::Medelement::ProviderCommandConfirmationJob)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'confirmation', 'status')).to eq('confirmed')
    expect(command.confirmation_request.reload).to have_attributes(
      status: 'confirmed',
      resolution_source: 'manual',
      resolved_by: agent
    )
  end

  it 'system-confirms an automatic dashboard command without a second user prompt' do
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      idempotency_key: 'dashboard-auto-confirm-command',
      actor: agent
    ).perform

    expect do
      post "#{path}/#{command.id}/confirm",
           params: { automatic: true },
           headers: headers,
           as: :json
    end.to have_enqueued_job(Integrations::Medelement::ProviderCommandConfirmationJob)

    expect(response).to have_http_status(:ok)
    expect(command.confirmation_request.reload).to have_attributes(
      status: 'confirmed',
      resolution_source: 'system',
      resolved_by: agent
    )
    expect(command.confirmation_request.resolution_metadata).to include(
      'medelement_auto_sync' => true,
      'surface' => 'onelink_outbound_change'
    )
  end

  it 'does not confirm a command from another account' do
    other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
    other_contact = create(:contact, account: other_account)
    other_hook = create(:integrations_hook, :medelement, account: other_account)
    other_command = create_command(account: other_account, hook: other_hook, contact: other_contact)

    post "#{path}/#{other_command.id}/confirm", headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
  end

  it 'cancels a stale command before its provider write is confirmed' do
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      idempotency_key: 'stale-dashboard-command',
      actor: agent
    ).perform

    expect do
      post "#{path}/#{command.id}/cancel", headers: headers, as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'status')).to eq('cancelled')
    expect(command.reload).to be_cancelled
    expect(command.confirmation_request).to be_pending
  end

  it 'manually cancels a command awaiting reconciliation and exposes retry state' do
    command = create_command(
      account: account,
      hook: hook,
      contact: contact,
      status: 'reconciliation_required',
      execution_state: {
        'reconciliation_attempts' => 2,
        'reconciliation_next_at' => 10.minutes.from_now.iso8601
      }
    )

    post "#{path}/#{command.id}/cancel", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch('payload')).to include(
      'status' => 'cancelled',
      'reconciliation_attempts' => 2,
      'reconciliation_next_at' => nil,
      'reconciliation_cancellable' => false,
      'last_error_code' => 'reconciliation_cancelled_manually'
    )
    expect(command.reload.execution_state).to include('reconciliation_cancelled_by_id' => agent.id)
  end

  it 'allows cancellation of a patient action only before any provider write' do
    command = build_patient_action_command(
      status: 'awaiting_patient_selection',
      patient_action: { 'type' => 'patient_selection', 'candidate_count' => 2 }
    )

    get "#{path}/#{command.id}", headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'patient_action', 'cancellable')).to be(true)

    post "#{path}/#{command.id}/cancel", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(command.reload).to be_cancelled
  end

  it 'rejects cancellation of a patient action after patient creation may have started' do
    command = build_patient_action_command(
      status: 'awaiting_phone_refresh',
      patient_action: { 'type' => 'phone_refresh', 'refresh_supported' => false }
    )
    command.update!(execution_state: command.execution_state.merge('write_phase' => 'patient_create'))

    get "#{path}/#{command.id}", headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'patient_action', 'cancellable')).to be(false)

    post "#{path}/#{command.id}/cancel", headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('MEDELEMENT_COMMAND_NOT_CANCELLABLE')
    expect(command.reload).to be_awaiting_phone_refresh
  end

  it 'keeps reconciliation after a possible write and does not advertise cancellation' do
    command = create_command(
      account: account, hook: hook, contact: contact, status: 'reconciliation_required',
      execution_state: { 'write_phase' => 'patient_create', 'reconciliation_attempts' => 1 }
    )

    get "#{path}/#{command.id}", headers: headers, as: :json
    expect(response.parsed_body.dig('payload', 'reconciliation_cancellable')).to be(false)

    post "#{path}/#{command.id}/cancel", headers: headers, as: :json
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('MEDELEMENT_COMMAND_NOT_CANCELLABLE')
    expect(command.reload).to be_reconciliation_required
  end

  it 'rejects cancellation while a provider command is queued for execution' do
    command = create_command(account: account, hook: hook, contact: contact, status: 'queued')

    post "#{path}/#{command.id}/cancel", headers: headers, as: :json

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['code']).to eq('MEDELEMENT_COMMAND_NOT_CANCELLABLE')
    expect(command.reload).to be_queued
  end

  it 'does not cancel a reconciliation command from another account' do
    other_account = create(:account).tap { |record| record.enable_features!('scheduling') }
    other_contact = create(:contact, account: other_account)
    other_hook = create(:integrations_hook, :medelement, account: other_account)
    other_command = create_command(
      account: other_account,
      hook: other_hook,
      contact: other_contact,
      status: 'reconciliation_required'
    )

    post "#{path}/#{other_command.id}/cancel", headers: headers, as: :json

    expect(response).to have_http_status(:not_found)
    expect(other_command.reload).to be_reconciliation_required
  end

  it 'returns opaque patient candidates and requeues the command after a valid selection', :aggregate_failures do
    command = build_patient_action_command(
      status: 'awaiting_patient_selection',
      patient_action: { 'type' => 'patient_selection', 'candidate_count' => 2 }
    )
    client = instance_double(Integrations::Medelement::Client)
    allow(Integrations::Medelement::Client).to receive(:new).and_return(client)
    allow(client).to receive(:search_patients_by_phone).and_return(
      [
        { 'PROFILE_CODE' => 'patient-1', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov', 'PATIENT_PHONE_2' => '+77001234567' },
        { 'PROFILE_CODE' => 'patient-2', 'NAME' => 'Ivan', 'LASTNAME' => 'Ivanov', 'PATIENT_PHONE_2' => '+77001234567' }
      ]
    )

    get "#{path}/#{command.id}/patient_candidates", headers: headers, as: :json

    candidates = response.parsed_body.dig('payload', 'candidates')
    expect(response).to have_http_status(:ok)
    expect(candidates.size).to eq(2)
    expect(candidates.first.fetch('token')).to match(/\A[0-9a-f]{64}\z/)
    expect(candidates.to_json).not_to include('patient-1', 'patient-2', 'PROFILE_CODE')

    expect do
      post "#{path}/#{command.id}/select_patient",
           params: { patient_token: candidates.first.fetch('token') },
           headers: headers,
           as: :json
    end.to have_enqueued_job(Integrations::Medelement::ProviderCommandJob).with(command.id)

    expect(response).to have_http_status(:ok)
    expect(command.reload).to be_queued
    expect(command.execution_state).not_to have_key('patient_action')
  end

  it 'rejects a forged patient candidate token without requeueing the command' do
    command = build_patient_action_command(
      status: 'awaiting_patient_selection',
      patient_action: { 'type' => 'patient_selection', 'candidate_count' => 1 }
    )

    expect do
      post "#{path}/#{command.id}/select_patient",
           params: { patient_token: 'forged' },
           headers: headers,
           as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)

    expect(response).to have_http_status(:conflict)
    expect(command.reload).to be_awaiting_patient_selection
  end

  it 'requeues an explicitly confirmed patient creation only when identity is complete' do
    command = build_patient_action_command(
      status: 'awaiting_patient_creation',
      patient_action: { 'type' => 'patient_creation', 'can_confirm' => true, 'missing_fields' => [] }
    )

    expect do
      post "#{path}/#{command.id}/confirm_patient_creation", headers: headers, as: :json
    end.to have_enqueued_job(Integrations::Medelement::ProviderCommandJob).with(command.id)

    expect(response).to have_http_status(:ok)
    expect(command.reload).to be_queued
    expect(command.execution_state).to include('patient_creation_confirmed' => true)
  end

  it 'requeues the same phone mismatch command without creating another command' do
    command = build_patient_action_command(
      status: 'awaiting_phone_refresh',
      patient_action: { 'type' => 'phone_refresh', 'refresh_supported' => false }
    )

    command_count = Integrations::Medelement::ProviderCommand.count
    expect do
      post "#{path}/#{command.id}/retry", headers: headers, as: :json
    end.to have_enqueued_job(Integrations::Medelement::ProviderCommandJob).with(command.id)

    expect(response).to have_http_status(:ok)
    expect(Integrations::Medelement::ProviderCommand.count).to eq(command_count)
    expect(command.reload).to be_queued
    expect(command.execution_state).to include('patient_phone_mismatch_accepted' => true)
    expect(command.execution_state).not_to have_key('patient_action')
  end

  it 'rejects retry for a command that is not waiting on a phone mismatch' do
    command = build_patient_action_command(
      status: 'awaiting_patient_selection',
      patient_action: { 'type' => 'patient_selection', 'candidate_count' => 1 }
    )

    expect do
      post "#{path}/#{command.id}/retry", headers: headers, as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandJob)

    expect(response).to have_http_status(:conflict)
    expect(command.reload).to be_awaiting_patient_selection
  end

  it 'queues only a read-only check for an unresolved reception create without repeating it immediately' do
    appointment = create(:scheduling_appointment, account: account, contact: contact)
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: 'create_reception', status: 'provider_status_unknown', company_cabinet_code: 'cabinet-1',
      idempotency_key: SecureRandom.uuid,
      execution_state: {
        'write_phase' => 'reception_create', 'reconciliation_next_at' => 1.day.from_now.iso8601
      }
    )

    expect do
      post "#{path}/#{command.id}/reconcile", headers: headers, as: :json
    end.to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob).with(command.id)
    expect(response).to have_http_status(:accepted)
    expect(command.reload).to be_provider_status_unknown
    expect(command.execution_state['reconciliation_dispatch_reserved_at']).to be_present

    expect do
      post "#{path}/#{command.id}/reconcile", headers: headers, as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob)
    expect(response).to have_http_status(:conflict)
  end

  it 'refuses a manual check when no reception write has started' do
    command = create_command(account: account, hook: hook, contact: contact)

    expect do
      post "#{path}/#{command.id}/reconcile", headers: headers, as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob)
    expect(response).to have_http_status(:conflict)
  end

  it 'does not claim a manual check which cannot run after bounded reconciliation was exhausted' do
    appointment = create(:scheduling_appointment, account: account, contact: contact)
    command = Integrations::Medelement::ProviderCommand.create!(
      account: account, hook: hook, appointment: appointment, contact: contact,
      operation: 'create_reception', status: 'reconciliation_required', company_cabinet_code: 'cabinet-1',
      idempotency_key: SecureRandom.uuid,
      execution_state: {
        'write_phase' => 'reception_create',
        'reconciliation_attempts' => Integrations::Medelement::ProviderCommand::RECONCILIATION_MAX_ATTEMPTS
      }
    )

    expect do
      post "#{path}/#{command.id}/reconcile", headers: headers, as: :json
    end.not_to have_enqueued_job(Integrations::Medelement::ProviderCommandReconciliationJob)
    expect(response).to have_http_status(:conflict)
  end

  private

  def build_patient_action_command(status:, patient_action:)
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      idempotency_key: SecureRandom.uuid,
      actor: agent
    ).perform
    command.update!(
      status: status,
      execution_state: command.execution_state.merge('patient_action' => patient_action)
    )
    command
  end

  def create_command(account:, hook:, contact:, status: 'failed', execution_state: {})
    Integrations::Medelement::ProviderCommand.create!(
      account: account,
      hook: hook,
      contact: contact,
      operation: 'create_patient',
      status: status,
      execution_state: execution_state,
      idempotency_key: SecureRandom.uuid
    )
  end
end
