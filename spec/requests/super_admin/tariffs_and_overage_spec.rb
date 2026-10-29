# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Approved 2026-10 OneLink tariffs and non-blocking AI overages', type: :request do
  let(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }

  describe 'Accounts::Plans 2026-10 tariff catalog and legacy archive' do
    it 'defines text_call, ai_agent_rop, voice_ai, enterprise as active tariffs and basic, pro, max as legacy archive' do
      expect(Accounts::Plans.active_tariff_keys).to eq(%w[text_call ai_agent_rop voice_ai enterprise])
      expect(Accounts::Plans.tariff_keys).to eq(%w[text_call ai_agent_rop voice_ai enterprise basic pro max])
      expect(Accounts::Plans.legacy_tariff?('basic')).to be(true)
      expect(Accounts::Plans.legacy_tariff?('pro')).to be(true)
      expect(Accounts::Plans.legacy_tariff?('max')).to be(true)
      expect(Accounts::Plans.legacy_tariff?('ai_agent_rop')).to be(false)
    end

    it 'defines approved KZT monthly, annual -15%, and annual total pricing across active and legacy tariffs' do
      expect(Accounts::Plans.tariff_pricing('text_call')).to include(
        'monthly_kzt' => 99_000, 'annual_monthly_kzt' => 85_000, 'annual_total_kzt' => 1_020_000,
        'extra_agent_kzt' => 10_000, 'extra_storage_10gb_kzt' => 3_000
      )
      expect(Accounts::Plans.tariff_pricing('ai_agent_rop')).to include(
        'monthly_kzt' => 199_000, 'annual_monthly_kzt' => 169_000, 'annual_total_kzt' => 2_028_000,
        'extra_agent_kzt' => 15_000, 'overage_ai_dialog_kzt' => 30, 'overage_call_minute_kzt' => 10
      )
      expect(Accounts::Plans.tariff_pricing('voice_ai')).to include(
        'monthly_kzt' => 399_000, 'annual_monthly_kzt' => 339_000, 'annual_total_kzt' => 4_068_000,
        'extra_agent_kzt' => 20_000
      )
      expect(Accounts::Plans.tariff_pricing('basic')).to include(
        'monthly_kzt' => 60_000, 'annual_monthly_kzt' => 51_000, 'annual_total_kzt' => 612_000
      )
      expect(Accounts::Plans.tariff_pricing('pro')).to include(
        'monthly_kzt' => 160_000, 'annual_monthly_kzt' => 136_000, 'annual_total_kzt' => 1_632_000
      )
      expect(Accounts::Plans.tariff_pricing('max')).to include(
        'monthly_kzt' => 300_000, 'annual_monthly_kzt' => 255_000, 'annual_total_kzt' => 3_060_000
      )
    end
  end

  describe 'applying tariffs, trials, switching to module builder, and non-blocking overage behavior' do
    it 'disables AI dialogs and call analysis on text_call (limit 0), except while an active 3-day AI trial is running' do
      Accounts::ApplyPlan.new(account: account, tariff: 'text_call', actor: super_admin).call
      account.reload

      expect(account.custom_attributes['plan_tariff']).to eq('text_call')
      expect(account.limits).to include('agents' => 5, 'captain_ai_dialogs' => 0, 'call_analysis_minutes' => 0)
      expect(account.captain_quota_available?).to be(false)
      expect(account.call_analysis_quota_available?).to be(false)

      account.activate_trial!(3)
      account.reload
      expect(account.trial_active?).to be(true)
      expect(account.captain_quota_available?).to be(true)
      expect(account.call_analysis_quota_available?).to be(true)
    end

    it 'cleans up tariff-written limits when switching from text_call or enterprise to module builder (tariff: nil)' do
      Accounts::ApplyPlan.new(account: account, tariff: 'text_call', actor: super_admin).call
      expect(account.reload.limits['captain_ai_dialogs']).to eq(0)

      Accounts::ApplyPlan.new(account: account, modules: ['ai_agents'], tariff: nil, actor: super_admin).call
      account.reload
      expect(account.custom_attributes['plan_tariff']).to be_nil
      expect(account.limits).not_to have_key('captain_ai_dialogs')
      expect(account.limits).not_to have_key('agents')
      expect(Accounts::LimitSettings.new(account).source('captain_ai_dialogs')).to eq(:plan)
      expect(account.captain_quota_available?).to be(true)
    end

    it 'NEVER blocks AI replies or call analysis when positive monthly limits are exceeded, even with legacy CAPTAIN_CLOUD_PLAN_LIMITS present' do
      InstallationConfig.where(name: 'CAPTAIN_CLOUD_PLAN_LIMITS').first_or_initialize.tap do |cfg|
        cfg.value = { 'starter' => { 'responses' => 10, 'tokens' => 1000 } }
        cfg.save!
      end
      Accounts::ApplyPlan.new(account: account, tariff: 'ai_agent_rop', actor: super_admin).call
      period = Accounts::MonthlyAiUsageService.new(account.reload).period_key
      account.update!(
        custom_attributes: account.custom_attributes.merge(
          'captain_responses_usage' => 999_999,
          'captain_tokens_usage' => 999_999_999,
          Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY => { period => 1250 },
          Accounts::MonthlyAiUsageService::CALL_SECONDS_MONTHLY_KEY => { period => 1120 * 60 }
        )
      )
      account.reload

      expect(account.limits).to include('agents' => 7, 'captain_ai_dialogs' => 1000, 'call_analysis_minutes' => 1000)
      expect(account.captain_quota_available?).to be(true)
      expect(account.call_analysis_quota_available?).to be(true)
      expect(account.usage_limits.dig(:captain, :ai_dialogs)).to include(overage_count: 250, overage_kzt: 7500, non_blocking_overage: true)
      expect(account.usage_limits.dig(:captain, :call_analysis_minutes)).to include(overage_count: 120, overage_kzt: 1200, non_blocking_overage: true)
    end

    it 'renders tariff presets, hides legacy tariffs in selectors, and supports bulk apply_plan with tariff param' do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
      sign_in(super_admin, scope: :super_admin)

      second_account = create(:account)
      get '/super_admin/account_bulk_actions/new', params: {
        bulk_action: 'apply_plan', chosen: '1', tariff: 'ai_agent_rop', account_ids: [account.id, second_account.id]
      }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('ИИ-Агент + ИИ-РОП')
      expect(response.body).not_to include('Basic (архив)')

      post '/super_admin/account_bulk_actions', params: {
        bulk_action: 'apply_plan', chosen: '1', tariff: 'ai_agent_rop', account_ids: [account.id, second_account.id]
      }
      expect([account.reload, second_account.reload].map { |acc| acc.custom_attributes['plan_tariff'] }).to eq(%w[ai_agent_rop ai_agent_rop])
      expect(account.limits['agents']).to eq(7)
    end

    it 'displays an assigned legacy tariff on the clinic card without leaking currency symbols' do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
      sign_in(super_admin, scope: :super_admin)

      Accounts::ApplyPlan.new(account: account, tariff: 'pro', actor: super_admin).call
      get "/super_admin/accounts/#{account.id}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Pro (архив)')
      expect(response.body).not_to match(/₸|тенге|KZT|\bруб\b/i)
    end
  end
end
