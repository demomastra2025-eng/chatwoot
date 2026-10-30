# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'OwnerFinance Fresh-Eyes Regression Suite', type: :model do
  describe 'CRITICAL #1: Exclusive owner workspace guard in DeadlineReminderService' do
    let(:owner) { create(:user) }
    let(:other_staff) { create(:user) }
    let(:shared_clinic_account) { create(:account, name: 'Клиентская клиника') }

    before do
      create(:account_user, account: shared_clinic_account, user: owner, role: :administrator)
      create(:account_user, account: shared_clinic_account, user: other_staff, role: :administrator)
      Crm::TaskStatus.find_or_create_by!(account_id: shared_clinic_account.id, code: 'todo') do |st|
        st.name = 'К выполнению'
        st.category = 'open'
        st.position = 1
      end
    end

    it 'refuses to create Crm::Task in a non-exclusive workspace or fall back to shared clinic accounts' do
      ref_date = Date.new(2026, 10, 30)
      dl = OwnerFinance::Deadline.create!(
        title: 'Личный налог ИП 910 форма', category: 'personal', payer_mode: 'us',
        due_on: ref_date, amount: 150_000, currency: 'KZT', recurrence: 'once'
      )

      with_modified_env(
        'OWNER_FINANCE_USER_ID' => owner.id.to_s,
        'OWNER_FINANCE_WORKSPACE_ACCOUNT_ID' => shared_clinic_account.id.to_s
      ) do
        res = OwnerFinance::DeadlineReminderService.new(reference_date: ref_date).perform
        expect(res[:reminded_count]).to eq(0)
        expect(Crm::Task.where(account_id: shared_clinic_account.id).count).to eq(0)
        expect(dl.reload.last_reminded_on).to be_nil
      end
    end
  end

  describe 'CRITICAL #2: Expense refund P&L math without double-counting' do
    it 'subtracts incoming expense_refund from expenses without inflating revenue in KPIs, breakdown, or monthly series' do
      OwnerFinance::TransactionRecord.create!(
        occurred_on: Date.new(2026, 10, 10), direction: 'income', pnl_treatment: 'pnl',
        official_status: 'official_1c', review_status: 'confirmed',
        amount: 200_000, currency: 'KZT', category: 'client_subscription', merchant: 'Клиника А'
      )
      OwnerFinance::TransactionRecord.create!(
        occurred_on: Date.new(2026, 10, 12), direction: 'expense', pnl_treatment: 'pnl',
        official_status: 'management', review_status: 'confirmed',
        amount: 50_000, currency: 'KZT', category: 'servers_and_cloud', merchant: 'Contabo'
      )
      OwnerFinance::TransactionRecord.create!(
        occurred_on: Date.new(2026, 10, 15), direction: 'income', pnl_treatment: 'expense_refund',
        official_status: 'management', review_status: 'confirmed',
        amount: 10_000, currency: 'KZT', category: 'servers_and_cloud', merchant: 'Contabo Refund'
      )

      dash = OwnerFinance::DashboardQueryService.new(year: 2026, month: 10, reference_date: Date.new(2026, 10, 30)).perform
      expect(dash[:kpis]).to include(
        month_revenue_kzt: 200_000.0,
        month_expenses_kzt: 40_000.0,
        month_net_profit_kzt: 160_000.0
      )
      oct_point = dash[:monthly_series].find { |pt| pt[:month] == 10 }
      expect(oct_point).to include(revenue_kzt: 200_000.0, expenses_kzt: 40_000.0, net_profit_kzt: 160_000.0)
      expect(dash[:expense_breakdown].first[:amount_kzt]).to eq(40_000.0)
    end
  end

  describe 'CRITICAL #3 & HIGH #5: External hide tombstones, counterparty scrubbing, and currency amount_kzt updates' do
    it 'prevents hidden external rows from resurrecting and scrubs auto-learned personal counterparties' do
      OwnerFinance::Counterparty.create!(
        display_name: 'Secret Store', normalized_key: 'secret store',
        kind: 'vendor', default_category: 'office_and_ops', default_pnl_treatment: 'pnl'
      )
      tx = OwnerFinance::TransactionRecord.create!(
        occurred_on: Date.new(2026, 10, 20), direction: 'expense', pnl_treatment: 'pnl',
        official_status: 'management', review_status: 'confirmed',
        amount: 8500, currency: 'KZT', category: 'office_and_ops',
        merchant: 'Secret Store', external_source_key: 'supabase:tx:99999'
      )

      OwnerFinance::PersonalHideService.new(transaction: tx, hide_merchant_always: true).perform
      expect(OwnerFinance::Counterparty.find_by(normalized_key: 'secret store')).to be_nil
      expect(OwnerFinance::PersonalTombstone.hidden_record?(external_source_key: 'supabase:tx:99999')).to be(true)
    end

    it 'recomputes amount_kzt when editing foreign currency amount or switching KZT to USD' do
      tx = OwnerFinance::TransactionRecord.create!(
        occurred_on: Date.new(2026, 10, 22), direction: 'expense', pnl_treatment: 'pnl',
        official_status: 'management', review_status: 'confirmed',
        amount: 100, currency: 'KZT', category: 'ai_and_llm', merchant: 'OpenRouter'
      )
      expect(tx.amount_kzt).to eq(BigDecimal(100))

      tx.update!(currency: 'USD')
      expect(tx.reload.amount_kzt).to eq(BigDecimal(49_000))

      tx.update!(amount: 20)
      expect(tx.reload.amount_kzt).to eq(BigDecimal(9800))
    end
  end

  describe 'MEDIUM #3: Anchor-preserving Deadline recurrence when completed late' do
    it 'keeps the exact annual expiry day even when renewed 4 days overdue' do
      dl = OwnerFinance::Deadline.create!(
        title: 'Продление домена kuanov.kz', category: 'client_domain',
        payer_mode: 'rebill_client', due_on: Date.new(2026, 11, 1),
        amount: 6500, currency: 'KZT', recurrence: 'yearly'
      )

      dl.advance_or_complete!(reference_date: Date.new(2026, 11, 5))
      expect(dl.reload.due_on).to eq(Date.new(2027, 11, 1))
    end
  end
end
