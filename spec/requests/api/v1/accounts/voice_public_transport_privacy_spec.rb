require 'rails_helper'

# Regression copied from the independent public-boundary privacy inventory.
RSpec.describe 'Public voice transport privacy', type: :request do
  it 'omits raw AI policies from every public copy while preserving private snapshots and business flags', :aggregate_failures do
    account = create(:account)
    account.enable_features!('channel_voice')
    admin = create(:user, account: account, role: :administrator)
    headers = { api_access_token: admin.access_token.token }
    archive = { 'system_prompt' => 'PRIVATE_FINAL_AI_PROMPT', 'archive' => { 'prompt' => 'PRIVATE_FINAL_AI_ARCHIVE' } }
    wa = create(:channel_whatsapp_web, account: account, provider_config: { 'ai_voice_settings' => archive, 'ai_voice_enabled' => false })
    sip = create(:channel_voice, :sipuni, account: account)
    sip.update!(provider_config: sip.provider_config.merge('ai_voice_settings' => archive, 'ai_voice_enabled' => false))
    snapshots = [wa.reload.provider_config.deep_dup, sip.reload.provider_config.deep_dup]
    builder = Telephony::VirtualPbx::ConfigBuilder.new(account: account)
    private_snapshot = builder.for_inbox(sip.inbox.id).deep_dup
    base = "/api/v1/accounts/#{account.id}"
    cases = [
      ['WAWeb show', "#{base}/inboxes/#{wa.inbox.id}", %w[provider_config]],
      ['WAWeb list', "#{base}/inboxes", nil],
      ['vPBX show diagnostics', "#{base}/telephony/virtual_pbx_channels/#{sip.inbox.id}?include_diagnostics=true",
       %w[payload diagnostics config provider_config]],
      ['vPBX status diagnostics', "#{base}/telephony/virtual_pbx_channels/#{sip.inbox.id}/status?include_diagnostics=true",
       %w[payload diagnostics config provider_config]],
      ['Readiness', "#{base}/telephony/resources/readiness", nil]
    ]

    cases.each do |name, path, keys|
      get path, headers: headers, as: :json
      body = response.parsed_body
      public_config = if name == 'WAWeb list'
                        body.fetch('payload').find { |item| item['id'] == wa.inbox.id }.fetch('provider_config')
                      elsif name == 'Readiness'
                        body.dig('payload', 'inboxes').find { |item| item['id'] == sip.inbox.id }.dig('virtual_pbx', 'provider_config')
                      else
                        body.dig(*keys)
                      end

      expect(response).to have_http_status(:ok), name
      expect(public_config).not_to have_key('ai_voice_settings'), name
      expect(public_config).to include('ai_voice_enabled' => false), name
      expect(response.body).not_to include('PRIVATE_FINAL_AI_PROMPT', 'PRIVATE_FINAL_AI_ARCHIVE'), name
    end

    expect([wa.reload.provider_config, sip.reload.provider_config]).to eq(snapshots)
    expect(builder.for_inbox(sip.inbox.id)).to eq(private_snapshot)
  end
end
