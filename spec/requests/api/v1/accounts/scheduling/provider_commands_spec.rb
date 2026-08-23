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
