require 'rails_helper'

RSpec.describe 'Integration Hooks API', type: :request do
  around do |example|
    with_modified_env('FRONTEND_URL' => 'https://app.example.com', 'MEDELEMENT_INTEGRATOR_KEY' => 'project-integrator-key') do
      example.run
    end
  end

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:params) { { app_id: 'dialogflow', inbox_id: inbox.id, settings: { project_id: 'xx', credentials: { test: 'test' }, region: 'europe-west1' } } }
  let(:macrocrm_params) do
    {
      app_id: 'macrocrm',
      access_token: 'macro-secret',
      status: 'enabled',
      settings: {
        app_id: 'macro-app',
        sync_incoming_messages: true,
        sync_outgoing_messages: false
      }
    }
  end
  let(:medelement_params) do
    {
      app_id: 'medelement',
      status: 'enabled',
      secret_settings: {
        company_login: 'company-login',
        password: 'super-secret'
      },
      settings: {
        timezone: 'Asia/Almaty',
        sync_specialists: true,
        sync_receptions: true,
        sync_patients: true,
        sync_interval_hours: 24,
        sync_time_of_day: '06:15',
        receptions_days_back: 3,
        receptions_days_forward: 70,
        throttle_ms: 0
      }
    }
  end

  before do
    allow_any_instance_of(Integrations::Medelement::CronScheduleService).to receive(:sync!).and_return(true)
    allow_any_instance_of(Integrations::Medelement::CronScheduleService).to receive(:destroy!).and_return(true)
  end

  describe 'POST /api/v1/accounts/{account.id}/integrations/hooks' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'return unauthorized if agent' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates hooks if admin' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['app_id']).to eq params[:app_id]
        expect(data['resource_id']).to eq params[:app_id]
      end

      it 'rejects hooks for removed or unregistered integrations' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: { app_id: 'postiz' },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(Integrations::Hook.exists?(account: account, app_id: 'postiz')).to be(false)
      end

      it 'creates a macrocrm hook with an encrypted access token' do
        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: macrocrm_params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        hook = Integrations::Hook.last

        expect(hook.app_id).to eq 'macrocrm'
        expect(hook.access_token).to eq 'macro-secret'
        expect(hook.reference_id).to be_present
        expect(hook.settings['app_id']).to eq 'macro-app'
        expect(response.parsed_body).not_to have_key('access_token')
        expect(response.parsed_body['reference_id']).to eq(hook.reference_id)
        expect(response.parsed_body['resource_id']).to eq('macrocrm')
        expect(response.parsed_body.dig('metadata', 'webhook_url')).to eq(
          "https://app.example.com/webhooks/macrocrm/#{hook.reference_id}/manager_changed"
        )
      end

      it 'creates a medelement hook with encrypted secret settings' do
        account.enable_features!('scheduling')

        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: medelement_params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        hook = Integrations::Hook.last

        expect(hook.app_id).to eq 'medelement'
        expect(hook.secret_settings).not_to have_key('integrator_key')
        expect(hook.secret_settings['company_login']).to eq 'company-login'
        expect(hook.secret_settings['password']).to eq 'super-secret'
        expect(hook.settings['sync_interval_hours']).to eq(24)
        expect(hook.settings['sync_time_of_day']).to eq('06:15')
        expect(response.parsed_body).not_to have_key('access_token')
      end

      it 'creates a medelement hook with a 15 minute sync interval' do
        account.enable_features!('scheduling')

        post api_v1_account_integrations_hooks_url(account_id: account.id),
             params: medelement_params.deep_merge(settings: { sync_interval_hours: 0.25 }),
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(Integrations::Hook.last.settings['sync_interval_hours']).to eq(0.25)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}' do
    let(:hook) { create(:integrations_hook, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: params,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'return unauthorized if agent' do
        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: params,
              headers: agent.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates hook if admin' do
        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: params,
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        data = response.parsed_body
        expect(data['app_id']).to eq 'slack'
        expect(data['resource_id']).to eq 'slack'
      end

      it 'updates macrocrm settings without clearing an existing token when a blank token is submitted' do
        hook = create(:integrations_hook,
                      account: account,
                      app_id: 'macrocrm',
                      access_token: 'existing-secret',
                      settings: {
                        'app_id' => 'macro-app',
                        'sync_incoming_messages' => true,
                        'sync_outgoing_messages' => true
                      })

        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: {
                status: false,
                access_token: '',
                settings: {
                  app_id: 'macro-app-updated',
                  sync_incoming_messages: false,
                  sync_outgoing_messages: true
                }
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(hook.reload.access_token).to eq 'existing-secret'
        expect(hook.reference_id).to be_present
        expect(hook.disabled?).to be true
        expect(hook.settings['app_id']).to eq 'macro-app-updated'
        expect(hook.settings['sync_incoming_messages']).to be false
        expect(response.parsed_body['resource_id']).to eq('macrocrm')
        expect(response.parsed_body.dig('metadata', 'webhook_url')).to eq(
          "https://app.example.com/webhooks/macrocrm/#{hook.reference_id}/manager_changed"
        )
      end

      it 'keeps existing medelement secret settings when blank values are submitted' do
        account.enable_features!('scheduling')
        hook = create(:integrations_hook, :medelement, account: account)

        patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
              params: {
                status: false,
                secret_settings: {
                  integrator_key: '',
                  company_login: '',
                  password: ''
                },
                settings: hook.settings.merge('throttle_ms' => 500, 'sync_interval_hours' => 12, 'sync_time_of_day' => '10:30')
              },
              headers: admin.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(hook.reload.secret_settings['integrator_key']).to eq('integration-key')
        expect(hook.secret_settings['company_login']).to eq('company-login')
        expect(hook.secret_settings['password']).to eq('super-secret')
        expect(hook.settings['throttle_ms']).to eq(500)
        expect(hook.settings['sync_interval_hours']).to eq(12)
        expect(hook.settings['sync_time_of_day']).to eq('10:30')
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}/run_sync' do
    let(:hook) { create(:integrations_hook, :medelement, account: account) }

    before do
      account.enable_features!('scheduling')
      allow(Integrations::Medelement::SyncJob).to receive(:perform_later)
    end

    it 'queues Medelement sync for an admin' do
      post run_sync_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body['message']).to eq('Medelement sync queued successfully')
      run = Integrations::Medelement::SyncRun.last
      expect(response.parsed_body.dig('sync_status', 'run', 'id')).to eq(run.id)
      expect(run).to have_attributes(trigger: 'manual', requested_by: admin)
      expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(hook.id, run.id)
    end

    it 'returns unauthorized for an agent' do
      post run_sync_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects manual sync for a disabled hook' do
      hook.disable

      post run_sync_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['message']).to eq('Medelement hook must be enabled before running a sync')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}/sync_status' do
    let(:hook) { create(:integrations_hook, :medelement, account: account) }

    before { account.enable_features!('scheduling') }

    it 'returns the latest run and actionable conflicts for an admin' do
      run = Integrations::Medelement::SyncRun.create!(
        account: account,
        hook: hook,
        requested_by: admin,
        trigger: 'manual',
        status: 'partial'
      )
      Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
        phase: 'services',
        entity_type: 'service',
        conflict_type: 'invalid_service',
        entity_key: 'service-1',
        details: { reason: 'missing name' }
      )

      get sync_status_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('run', 'id')).to eq(run.id)
      expect(response.parsed_body.dig('conflict_counts', 'open')).to eq(1)
      expect(response.parsed_body.dig('conflicts', 0, 'conflict_type')).to eq('invalid_service')
    end

    it 'returns unauthorized for an agent' do
      get sync_status_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'filters the queue by status, type, date, and account-scoped contact query' do
      contact = create(:contact, account: account, name: 'Filter Patient')
      run = Integrations::Medelement::SyncRun.create!(
        account: account,
        hook: hook,
        requested_by: admin,
        trigger: 'manual',
        status: 'partial'
      )
      matching = Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
        phase: 'contacts',
        entity_type: 'contact',
        conflict_type: 'phone_owned_by_another_contact',
        entity_key: 'patient-filter',
        details: { contact_id: contact.id }
      )
      matching.ignore!(user: admin, note: 'Separate patients')

      get sync_status_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
          params: {
            status: 'ignored',
            conflict_type: 'phone_owned_by_another_contact',
            contact: 'Filter Patient',
            from: 1.day.ago.to_date.iso8601,
            to: Date.current.iso8601
          },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['conflicts'].pluck('id')).to eq([matching.id])
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}/sync_conflict' do
    let(:hook) { create(:integrations_hook, :medelement, account: account) }
    let(:run) do
      Integrations::Medelement::SyncRun.create!(
        account: account,
        hook: hook,
        trigger: 'manual',
        status: 'partial'
      )
    end
    let(:conflict) do
      Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
        phase: 'receptions',
        entity_type: 'reception',
        conflict_type: 'invalid_reception',
        entity_key: 'reception-1'
      )
    end

    before { account.enable_features!('scheduling') }

    it 'allows an admin to ignore a conflict' do
      patch sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
            params: { conflict_id: conflict.id, resolution: 'ignore' },
            headers: admin.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(conflict.reload).to have_attributes(status: 'ignored', resolved_by: admin)
    end

    it 'allows an admin to reopen an ignored conflict' do
      conflict.ignore!(user: admin)

      patch sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
            params: { conflict_id: conflict.id, resolution: 'reopen' },
            headers: admin.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:ok)
      expect(conflict.reload).to have_attributes(status: 'open', resolved_by: nil)
    end

    it 'does not allow an agent to mutate a conflict' do
      patch sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
            params: { conflict_id: conflict.id, resolution: 'ignore' },
            headers: agent.create_new_auth_token,
            as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(conflict.reload).to be_open
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}/resolve_sync_conflict' do
    let(:hook) { create(:integrations_hook, :medelement, account: account) }
    let(:run) do
      Integrations::Medelement::SyncRun.create!(
        account: account,
        hook: hook,
        trigger: 'manual',
        status: 'partial'
      )
    end
    let(:primary_contact) { create(:contact, account: account) }
    let(:conflicting_contact) { create(:contact, account: account) }
    let(:conflict) do
      Integrations::Medelement::ConflictTracker.new(sync_run: run).record!(
        phase: 'contacts',
        entity_type: 'contact',
        conflict_type: 'phone_owned_by_another_contact',
        entity_key: 'patient-1',
        details: { contact_id: primary_contact.id, conflicting_contact_id: conflicting_contact.id }
      )
    end

    before { account.enable_features!('scheduling') }

    it 'allows an admin to keep contacts separate with an audit note' do
      post resolve_sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: { conflict_id: conflict.id, resolution: 'keep_separate', note: 'Different patients' },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(conflict.reload).to have_attributes(status: 'ignored', resolution_note: 'Different patients', resolved_by: admin)
    end

    it 'allows an admin to merge the recorded contacts' do
      post resolve_sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: {
             conflict_id: conflict.id,
             resolution: 'merge',
             base_contact_id: primary_contact.id,
             mergee_contact_id: conflicting_contact.id
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(Contact.exists?(conflicting_contact.id)).to be(false)
      expect(conflict.reload).to have_attributes(status: 'resolved', resolved_by: admin)
    end

    it 'dispatches selected field synchronization with its direction' do
      field_service = instance_double(Integrations::Medelement::ContactFieldResolutionService, perform: nil)
      allow(Integrations::Medelement::ContactFieldResolutionService).to receive(:new).and_return(field_service)

      post resolve_sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: {
             conflict_id: conflict.id,
             resolution: 'sync_fields',
             field_directions: {
               first_name: 'medelement_to_onelink',
               phone: 'onelink_to_medelement'
             }
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:ok)
      expect(field_service).to have_received(:perform).with(
        field_directions: ActionController::Parameters.new(
          first_name: 'medelement_to_onelink',
          phone: 'onelink_to_medelement'
        )
      )
    end

    it 'returns a structured response when a synchronized field belongs to another contact' do
      error = Integrations::Medelement::ContactFieldResolutionService::FieldAlreadyUsedError.new(
        field: 'iin',
        contact_id: conflicting_contact.id
      )
      field_service = instance_double(Integrations::Medelement::ContactFieldResolutionService)
      allow(field_service).to receive(:perform).and_raise(error)
      allow(Integrations::Medelement::ContactFieldResolutionService).to receive(:new).and_return(field_service)

      post resolve_sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: {
             conflict_id: conflict.id,
             resolution: 'sync_fields',
             field_directions: { iin: 'medelement_to_onelink' }
           },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to include(
        'code' => 'contact_field_already_used',
        'field' => 'iin',
        'contact_id' => conflicting_contact.id
      )
    end

    it 'rejects unsafe deletion and preserves the conflict' do
      create(:message, sender: conflicting_contact)

      post resolve_sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: { conflict_id: conflict.id, resolution: 'delete', contact_id: conflicting_contact.id },
           headers: admin.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('unsafe_resolution')
      expect(conflict.reload).to be_open
    end

    it 'does not allow an agent to resolve a contact conflict' do
      post resolve_sync_conflict_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: { conflict_id: conflict.id, resolution: 'keep_separate', note: 'Different patients' },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(conflict.reload).to be_open
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}/process_event' do
    let(:hook) { create(:integrations_hook, account: account) }
    let(:params) { { event: 'rephrase', payload: { test: 'test' } } }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post process_event_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
             params: params,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'returns unauthorized if agent' do
        post process_event_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
             params: params,
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns an error for unsupported hook events' do
        post process_event_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
             params: params,
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['error']).to eq 'No processor found'
      end

      it 'enqueues a manual medelement sync for admin' do
        account.enable_features!('scheduling')
        medelement_hook = create(:integrations_hook, :medelement, account: account)
        allow(Integrations::Medelement::SyncJob).to receive(:perform_later)

        post process_event_api_v1_account_integrations_hook_url(account_id: account.id, id: medelement_hook.id),
             params: { event: 'sync' },
             headers: admin.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['message']).to eq 'Medelement sync started'
        run = Integrations::Medelement::SyncRun.last
        expect(Integrations::Medelement::SyncJob).to have_received(:perform_later).with(medelement_hook.id, run.id)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/integrations/hooks/{hook_id}' do
    let(:hook) { create(:integrations_hook, account: account) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      it 'return unauthorized if agent' do
        delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates hook if admin' do
        delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
               headers: admin.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(Integrations::Hook.exists?(hook.id)).to be false
      end

      it 'cleans up Medelement imported scheduling data only for the disconnected account' do
        account.enable_features!('scheduling')
        other_account = create(:account)
        other_account.enable_features!('scheduling')

        hook = create(:integrations_hook, :medelement, account: account)
        create(:integrations_hook, :medelement, account: other_account)

        resource_with_manual_data = create(
          :scheduling_resource,
          account: account,
          custom_attributes: {
            'medelement_specialist_code' => '27492901726817790',
            'medelement_cabinets' => [{ 'companyCabinetCode' => 'cab-1' }],
            'medelement_reception_time' => 20,
            'medelement_schedule_published' => 1
          }
        )
        removable_resource = create(
          :scheduling_resource,
          account: account,
          custom_attributes: {
            'medelement_specialist_code' => '27492901726817791'
          }
        )
        other_account_resource = create(
          :scheduling_resource,
          account: other_account,
          custom_attributes: {
            'medelement_specialist_code' => 'other-account-specialist'
          }
        )

        manual_appointment = create(
          :scheduling_appointment,
          account: account,
          resource: resource_with_manual_data,
          source: 'manual',
          external_ref: nil
        )
        create(
          :scheduling_appointment,
          account: account,
          resource: resource_with_manual_data,
          source: 'medelement',
          external_ref: 'medelement:reception:1'
        )
        create(
          :scheduling_appointment,
          account: account,
          resource: removable_resource,
          source: 'medelement',
          external_ref: 'medelement:reception:2'
        )
        create(
          :scheduling_appointment,
          account: other_account,
          resource: other_account_resource,
          source: 'medelement',
          external_ref: 'medelement:reception:other'
        )

        perform_enqueued_jobs(only: Integrations::Medelement::CleanupJob) do
          delete api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
                 headers: admin.create_new_auth_token,
                 as: :json
        end

        expect(response).to have_http_status(:success)
        expect(account.scheduling_appointments.where(source: 'medelement')).to be_empty
        expect(other_account.scheduling_appointments.where(source: 'medelement').count).to eq(1)
        expect(Scheduling::Appointment.exists?(manual_appointment.id)).to be true
        expect(resource_with_manual_data.reload.custom_attributes['medelement_specialist_code']).to be_blank
        expect(Scheduling::Resource.exists?(removable_resource.id)).to be false
        expect(other_account_resource.reload.custom_attributes['medelement_specialist_code']).to eq('other-account-specialist')
      end
    end
  end
end
