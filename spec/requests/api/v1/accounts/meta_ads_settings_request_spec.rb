# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Account Meta Ads Settings API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:outsider) { create(:user) }

  describe 'GET /api/v1/accounts/:account_id/meta_ads_settings' do
    it 'returns auto_tag_enabled true by default and aggregates recent ad sources for members' do
      conv = create(:conversation, account: account)
      MetaAdReferral.create!(
        account: account,
        inbox: conv.inbox,
        conversation: conv,
        contact: conv.contact,
        provider: 'whatsapp',
        provider_message_id: 'wamid.test-ref-1',
        source_id: '120214555001',
        headline: 'Чекап -30%',
        received_at: Time.current
      )

      get "/api/v1/accounts/#{account.id}/meta_ads_settings",
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['auto_tag_enabled']).to be(true)
      expect(body.dig('system_label', 'display_title')).to eq('Meta Ads')
      expect(body.dig('system_label', 'color')).to eq('#1F93FF')
      expect(body['recent_sources']).to contain_exactly(
        a_hash_including(
          'source_id' => '120214555001',
          'headline' => 'Чекап -30%',
          'referrals_count' => 1
        )
      )
    end

    it 'denies access to users outside the account' do
      get "/api/v1/accounts/#{account.id}/meta_ads_settings",
          headers: outsider.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
    end
  end

  describe 'PUT /api/v1/accounts/:account_id/meta_ads_settings' do
    it 'forbids non-admin agents from modifying settings' do
      put "/api/v1/accounts/#{account.id}/meta_ads_settings",
          params: { auto_tag_enabled: false },
          headers: agent.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:unauthorized).or have_http_status(:forbidden)
      expect(Meta::AdReferralAutoTagger.auto_tag_enabled?(account.reload)).to be(true)
    end

    it 'allows administrators to disable auto_tag_enabled' do
      put "/api/v1/accounts/#{account.id}/meta_ads_settings",
          params: { auto_tag_enabled: false },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['auto_tag_enabled']).to be(false)
      expect(Meta::AdReferralAutoTagger.auto_tag_enabled?(account.reload)).to be(false)
    end

    it 'auto-creates the blue system Meta Ads label when enabled by an administrator' do
      account.update!(custom_attributes: { 'meta_ads_auto_tag' => false })

      put "/api/v1/accounts/#{account.id}/meta_ads_settings",
          params: { auto_tag_enabled: true },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['auto_tag_enabled']).to be(true)
      expect(response.parsed_body.dig('system_label', 'exists')).to be(true)
      sys_label = account.reload.labels.find_by(title: 'meta_ads')
      expect(sys_label).to have_attributes(display_title: 'Meta Ads', color: '#1F93FF')
    end

    it 'persists source_rules and strips cross-account label IDs' do
      promo_label = account.labels.create!(title: 'checkup_30', display_title: 'Чекап -30%', color: '#22C55E')
      other_account_label = create(:account).labels.create!(title: 'foreign_tag', display_title: 'Foreign')

      put "/api/v1/accounts/#{account.id}/meta_ads_settings",
          params: {
            source_rules: [
              { source_id: ' 120214555001 ', label_ids: [promo_label.id, other_account_label.id] },
              { source_id: '999999', label_ids: [other_account_label.id] }
            ]
          },
          headers: admin.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:ok)
      rules = response.parsed_body['source_rules']
      expect(rules).to eq(
        [
          {
            'source_id' => '120214555001',
            'label_ids' => [promo_label.id],
            'labels' => [
              {
                'id' => promo_label.id,
                'title' => 'checkup_30',
                'display_title' => 'Чекап -30%',
                'color' => '#22C55E'
              }
            ]
          }
        ]
      )
      expect(account.reload.custom_attributes['meta_ads_source_label_map']).to eq(
        '120214555001' => [promo_label.id]
      )
    end

    it 'clears source_rules and handles malformed nested label_ids safely' do
      auth_headers = admin.create_new_auth_token
      promo_label = account.labels.create!(title: 'checkup_30', display_title: 'Чекап -30%', color: '#22C55E')
      account.update!(custom_attributes: { 'meta_ads_source_label_map' => { '120214555001' => [promo_label.id] } })

      put "/api/v1/accounts/#{account.id}/meta_ads_settings",
          params: { source_rules: [{ source_id: '120214555001', label_ids: { '0' => promo_label.id } }] },
          headers: auth_headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig('source_rules', 0, 'label_ids')).to eq([promo_label.id])

      put "/api/v1/accounts/#{account.id}/meta_ads_settings",
          params: { source_rules: [] },
          headers: auth_headers,
          as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['source_rules']).to eq([])
      expect(account.reload.custom_attributes['meta_ads_source_label_map']).to eq({})
    end
  end
end
