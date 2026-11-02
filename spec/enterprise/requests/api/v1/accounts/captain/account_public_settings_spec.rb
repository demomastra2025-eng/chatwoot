require 'rails_helper'

RSpec.describe 'Account public settings contract', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:platform) { create(:super_admin).tap { |user| create(:account_user, account: account, user: user, role: :administrator) } }
  let(:marker) { '__ACCOUNT_RAW_PROMPT__' }

  def stored_settings
    {
      'captain_runtime' => { 'audio_transcription_prompt' => marker, 'future_archive' => { 'description' => marker } },
      'captain_models' => { 'assistant' => 'platform/model' }, 'future_archive' => { 'description' => marker },
      'workspace_timezone' => 'Asia/Almaty',
      'workspace_greeting' => { 'enabled' => false, 'message' => nil, 'excluded_inbox_ids' => nil },
      'workspace_out_of_office' => { 'enabled' => true, 'message' => 'We reopen at 09:00' },
      'workspace_working_hours' => [{ 'day_of_week' => 1, 'closed_all_day' => false, 'open_all_day' => true }],
      'workspace_breaks' => [{ 'title' => 'Lunch', 'start_time' => '13:00', 'end_time' => '14:00', 'days' => [1], 'archive' => marker }],
      'workspace_days_off' => [{ 'date' => '2026-12-31', 'title' => 'Holiday', 'recurring_yearly' => false }]
    }
  end

  before do
    # rubocop:disable Rails/SkipsModelValidations -- historical JSON can contain keys outside today's write schema
    account.update_column(:settings, stored_settings)
    # rubocop:enable Rails/SkipsModelValidations
  end

  it 'hides technical prompts, models and nested unknown archives from both ordinary roles while retaining business fields' do
    [admin, agent].each do |user|
      get "/api/v1/accounts/#{account.id}", headers: user.create_new_auth_token, as: :json
      expect(response).to have_http_status(:ok)
      public_settings = response.parsed_body.fetch('settings')
      expect(response.body).not_to include(marker, 'platform/model')
      expect(public_settings.slice('workspace_greeting', 'workspace_out_of_office', 'workspace_working_hours', 'workspace_days_off'))
        .to eq(stored_settings.slice('workspace_greeting', 'workspace_out_of_office', 'workspace_working_hours', 'workspace_days_off'))
      expect(public_settings['workspace_breaks']).to eq([stored_settings['workspace_breaks'].first.except('archive')])
    end
  end

  it 'applies the same runtime allowlist to Preferences for an administrator, including unknown nested archives' do
    get "/api/v1/accounts/#{account.id}/captain/preferences?client_metadata_only=true", headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(marker)
    expect(response.parsed_body.fetch('runtime')).to include('assistant_thinking_effort' => 'low')
  end

  it 'preserves the existing denial of Preferences to agents without exposing archived data' do
    get "/api/v1/accounts/#{account.id}/captain/preferences?client_metadata_only=true", headers: agent.create_new_auth_token, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include(marker)
  end

  it 'retains platform technical reads through both direct and verified impersonation access, excluding unknown archives' do
    get "/api/v1/accounts/#{account.id}", headers: platform.create_new_auth_token, as: :json
    expect(response.parsed_body.dig('settings', 'captain_runtime')).to eq('audio_transcription_prompt' => marker)
    grant = SuperAdmin::ImpersonationService.issue_grant!(actor: platform, account: account, target_user: admin)
    post '/auth/sign_in', params: { email: admin.email, sso_auth_token: grant.token }, as: :json
    headers = response.headers.slice('access-token', 'client', 'uid')
    get "/api/v1/accounts/#{account.id}", headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('settings', 'captain_runtime')).to eq('audio_transcription_prompt' => marker)
    expect(account.reload.settings).to eq(stored_settings)
  end
end
