require 'rails_helper'

RSpec.describe 'Super Admin app configs', type: :request do
  let(:super_admin) { create(:super_admin) }

  before do
    sign_in(super_admin, scope: :super_admin)
  end

  it 'persists zero as a valid call inbox quota' do
    post '/super_admin/app_config', params: {
      config: 'general',
      app_config: { 'ACCOUNT_CALL_INBOXES_LIMIT' => '0' }
    }

    expect(response).to redirect_to(super_admin_settings_path)
    expect(InstallationConfig.find_by!(name: 'ACCOUNT_CALL_INBOXES_LIMIT').value).to eq(0)
  end

  it 'rejects negative and non-numeric call inbox quotas without replacing the stored value' do
    config = InstallationConfig.where(name: 'ACCOUNT_CALL_INBOXES_LIMIT').first_or_initialize
    config.update!(value: 3, locked: false)

    ['-1', 'invalid'].each do |value|
      post '/super_admin/app_config', params: {
        config: 'general',
        app_config: { 'ACCOUNT_CALL_INBOXES_LIMIT' => value }
      }

      expect(response).to be_redirect
      expect(config.reload.value).to eq(3)
    end
  end

  it 'rejects non-scalar call inbox quotas without replacing the stored value' do
    config = InstallationConfig.where(name: 'ACCOUNT_CALL_INBOXES_LIMIT').first_or_initialize
    config.update!(value: 3, locked: false)

    [false, [], {}].each do |value|
      post '/super_admin/app_config', params: {
        config: 'general',
        app_config: { 'ACCOUNT_CALL_INBOXES_LIMIT' => value }
      }

      expect(response).to be_redirect
      expect(config.reload.value).to eq(3)
    end
  end

  it 'normalizes a whitespace-padded integer call inbox quota' do
    config = InstallationConfig.where(name: 'ACCOUNT_CALL_INBOXES_LIMIT').first_or_initialize
    config.update!(value: 3, locked: false)

    post '/super_admin/app_config', params: {
      config: 'general',
      app_config: { 'ACCOUNT_CALL_INBOXES_LIMIT' => ' 12 ' }
    }

    expect(response).to be_redirect
    expect(config.reload.value).to eq(12)
  end

  it 'rejects an invalid call quota through the generic installation config writer' do
    config = InstallationConfig.create!(name: 'ACCOUNT_CALL_INBOXES_LIMIT', value: 3, locked: false)

    patch "/super_admin/installation_configs/#{config.id}",
          params: { installation_config: { name: config.name, value: '-1' } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(config.reload.value).to eq(3)
  end

  it 'rejects a numeric fractional call quota through the generic installation config writer' do
    config = InstallationConfig.create!(name: 'ACCOUNT_CALL_INBOXES_LIMIT', value: 3, locked: false)

    patch "/super_admin/installation_configs/#{config.id}",
          params: { installation_config: { name: config.name, value: 0.5 } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(config.reload.value).to eq(3)
  end

  it 'preserves the Slack signing secret when the masked field is submitted blank' do
    config = InstallationConfig.where(name: 'SLACK_SIGNING_SECRET').first_or_initialize
    config.update!(value: 'existing-signing-secret', locked: false)

    post '/super_admin/app_config', params: {
      config: 'slack',
      app_config: { 'SLACK_SIGNING_SECRET' => '' }
    }

    expect(response).to redirect_to(super_admin_settings_path)
    expect(config.reload.value).to eq('existing-signing-secret')
  end
end
