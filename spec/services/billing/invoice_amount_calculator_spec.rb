# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Billing::InvoiceAmountCalculator do
  let(:account) { create(:account) }
  let(:period_start) { Date.new(2026, 11, 10) }

  def build_profile(attrs = {})
    Billing::AccountProfile.create!(
      { account: account, billing_enabled: true, paid_until: period_start }.merge(attrs)
    )
  end

  describe 'commercial plan tiers and add-ons' do
    it 'calculates text_call monthly and annual prices plus extra seats and storage packs' do
      Accounts::ApplyPlan.new(account: account, tariff: 'text_call').call
      monthly_profile = build_profile(extra_seats_count: 2, extra_storage_packs_count: 3)

      monthly = described_class.new(account: account, profile: monthly_profile, period_start: period_start).perform
      expect(monthly).to have_attributes(
        plan_key: 'text_call',
        base_amount_minor: 9_900_000,
        addons_amount_minor: 2_900_000,
        amount_minor: 12_800_000,
        partner_commission_base_minor: 9_900_000
      )

      monthly_profile.update!(annual_discount: true, extra_seats_count: 0, extra_storage_packs_count: 0)
      annual = described_class.new(account: account, profile: monthly_profile, period_start: period_start).perform
      expect(annual).to have_attributes(base_amount_minor: 8_500_000, amount_minor: 8_500_000)
    end

    it 'calculates ai_agent_rop and voice_ai tiers with annual -15% discounts and seat rates' do
      Accounts::ApplyPlan.new(account: account, tariff: 'ai_agent_rop').call
      profile = build_profile(annual_discount: true, extra_seats_count: 1)

      rop = described_class.new(account: account, profile: profile, period_start: period_start).perform
      expect(rop).to have_attributes(
        plan_key: 'ai_agent_rop', base_amount_minor: 16_900_000, addons_amount_minor: 1_500_000,
        partner_commission_base_minor: 16_900_000
      )

      Accounts::ApplyPlan.new(account: account, tariff: 'voice_ai').call
      profile.update!(annual_discount: false, extra_seats_count: 2)
      voice = described_class.new(account: account, profile: profile, period_start: period_start).perform
      expect(voice).to have_attributes(
        plan_key: 'voice_ai', base_amount_minor: 39_900_000, addons_amount_minor: 4_000_000,
        amount_minor: 43_900_000, partner_commission_base_minor: 39_900_000
      )
    end

    it 'uses custom_monthly_price_minor for enterprise and raises if enterprise has no custom price' do
      Accounts::ApplyPlan.new(account: account, tariff: 'enterprise').call
      profile = build_profile

      expect do
        described_class.new(account: account, profile: profile, period_start: period_start).perform
      end.to raise_error(ArgumentError, /Base monthly price is not configured/)

      profile.update!(custom_monthly_price_minor: 65_000_000)
      oct_time = Time.find_zone('Asia/Almaty').local(2026, 10, 20, 12, 0, 0)
      Accounts::MonthlyAiUsageService.new(account).record_call_analysis!(duration_seconds: 50_000 * 60, at: oct_time)

      ent = described_class.new(account: account, profile: profile, period_start: period_start).perform
      expect(ent).to have_attributes(
        plan_key: 'enterprise', base_amount_minor: 65_000_000,
        call_minutes_overage_minor: 0, amount_minor: 65_000_000
      )
    end
  end

  describe 'AI dialog (30 KZT) and call analysis (10 KZT/min) overage metering' do
    it 'bills previous month AI overages and excludes overages and addons from partner_commission_base_minor' do
      Accounts::ApplyPlan.new(account: account, tariff: 'ai_agent_rop').call
      profile = build_profile(extra_seats_count: 1)
      oct_time = Time.find_zone('Asia/Almaty').local(2026, 10, 18, 14, 0, 0)
      account.update!(
        custom_attributes: account.custom_attributes.to_h.merge(
          Accounts::MonthlyAiUsageService::AI_DIALOGS_MONTHLY_KEY => { '2026-10' => 1120 }
        )
      )
      Accounts::MonthlyAiUsageService.new(account).record_call_analysis!(duration_seconds: 1250 * 60, at: oct_time)

      res = described_class.new(account: account, profile: profile, period_start: period_start).perform

      expect(res).to have_attributes(
        usage_period_month: '2026-10',
        base_amount_minor: 19_900_000,
        addons_amount_minor: 1_500_000,
        ai_dialogs_overage_count: 120,
        ai_dialogs_overage_minor: 360_000,
        call_minutes_overage_count: 250,
        call_minutes_overage_minor: 250_000,
        amount_minor: 22_010_000,
        partner_commission_base_minor: 19_900_000
      )
    end
  end
end
