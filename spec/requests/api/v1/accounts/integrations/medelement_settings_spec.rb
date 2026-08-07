require 'rails_helper'

RSpec.describe 'Medelement integration settings', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  around do |example|
    with_modified_env('MEDELEMENT_INTEGRATOR_KEY' => 'project-integrator-key') { example.run }
  end

  before do
    account.enable_features!('scheduling')
    allow(Integrations::Medelement::CronScheduleService).to receive(:new).and_wrap_original do |constructor, **kwargs|
      constructor.call(**kwargs).tap do |service|
        allow(service).to receive(:sync!).and_return(true)
      end
    end
  end

  it 'stores confirmed provider writes enabled by the integration form' do
    post api_v1_account_integrations_hooks_url(account_id: account.id),
         params: {
           app_id: 'medelement',
           status: true,
           secret_settings: {
             company_login: 'company-login',
             password: 'company-password'
           },
           settings: {
             timezone: 'Asia/Almaty',
             write_enabled: true
           }
         },
         headers: admin.create_new_auth_token,
         as: :json

    expect(response).to have_http_status(:success)
    expect(account.hooks.find_by!(app_id: 'medelement').settings['write_enabled']).to be true
  end

  it 'updates the write setting without clearing existing credentials' do
    hook = create(:integrations_hook, :medelement, account: account)
    credentials = hook.secret_settings

    patch api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
          params: {
            status: true,
            secret_settings: {
              company_login: '',
              password: ''
            },
            settings: hook.settings.merge('write_enabled' => true)
          },
          headers: admin.create_new_auth_token,
          as: :json

    expect(response).to have_http_status(:success)
    expect(hook.reload.settings['write_enabled']).to be true
    expect(hook.secret_settings).to eq(credentials)
  end

  describe 'POST /import_catalog' do
    let(:hook) { create(:integrations_hook, :medelement, account: account) }
    let(:catalog_path) { Rails.public_path.join('downloads/medelement-catalog-sample.json') }

    it 'imports a valid account-scoped catalog file' do
      upload = Rack::Test::UploadedFile.new(catalog_path, 'application/json')

      post import_catalog_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: { file: upload },
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['result']).to include(
        'specialists' => { 'imported_count' => 1, 'skipped_count' => 0 },
        'services' => { 'imported_count' => 1, 'linked_count' => 1, 'skipped_count' => 0 }
      )
      expect(account.scheduling_service_prices.count).to eq(1)
    end

    it 'rejects invalid JSON without changing scheduling data' do
      Tempfile.create(['invalid-medelement-catalog', '.json']) do |file|
        file.write('{invalid')
        file.rewind
        upload = Rack::Test::UploadedFile.new(file.path, 'application/json')

        post import_catalog_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
             params: { file: upload },
             headers: admin.create_new_auth_token
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['code']).to eq('invalid_json')
      expect(account.scheduling_resources).to be_empty
      expect(account.scheduling_services).to be_empty
    end

    it 'does not allow catalog import through another integration type' do
      slack_hook = create(:integrations_hook, account: account)
      upload = Rack::Test::UploadedFile.new(catalog_path, 'application/json')

      post import_catalog_api_v1_account_integrations_hook_url(account_id: account.id, id: slack_hook.id),
           params: { file: upload },
           headers: admin.create_new_auth_token

      expect(response).to have_http_status(:not_found)
    end

    it 'forbids catalog import for non-administrators' do
      agent = create(:user, account: account, role: :agent)
      upload = Rack::Test::UploadedFile.new(catalog_path, 'application/json')

      post import_catalog_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: { file: upload },
           headers: agent.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects import while the account Medelement sync lock is busy' do
      lock_manager = instance_double(Redis::LockManager, lock: false, unlock: true)
      allow(Redis::LockManager).to receive(:new).and_return(lock_manager)
      upload = Rack::Test::UploadedFile.new(catalog_path, 'application/json')

      post import_catalog_api_v1_account_integrations_hook_url(account_id: account.id, id: hook.id),
           params: { file: upload },
           headers: admin.create_new_auth_token

      expected_key = format(Redis::Alfred::MEDELEMENT_SYNC_MUTEX, account_id: account.id)
      expect(lock_manager).to have_received(:lock).with(expected_key, 10.minutes)
      expect(lock_manager).not_to have_received(:unlock)
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body['code']).to eq('import_in_progress')
    end
  end
end
