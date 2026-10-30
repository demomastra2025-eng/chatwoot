# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'OwnerFinance Fresh-Eyes Regression Suite', type: :model do
  describe 'CRITICAL #1: Exclusive owner workspace guard & auto-provisioned CRM catalogs in DeadlineReminderService' do
    let(:owner) { create(:user) }
    let(:other_staff) { create(:user) }
    let(:shared_clinic_account) { create(:account, name: 'Клиентская клиника') }
    let(:exclusive_owner_account) { create(:account, name: 'Личный кабинет владельца') }

    before do
      create(:account_user, account: shared_clinic_account, user: owner, role: :administrator)
      create(:account_user, account: shared_clinic_account, user: other_staff, role: :administrator)
      create(:account_user, account: exclusive_owner_account, user: owner, role: :administrator)
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

    it 'auto-provisions Crm::TaskStatus and Crm::TaskType on an unbootstrapped exclusive workspace and creates reminder tasks' do
      expect(Crm::TaskStatus.where(account_id: exclusive_owner_account.id)).to be_empty
      expect(Crm::TaskType.where(account_id: exclusive_owner_account.id)).to be_empty

      ref_date = Date.new(2026, 10, 30)
      dl = OwnerFinance::Deadline.create!(
        title: 'Продление домена one-link.kz', category: 'own_domain', payer_mode: 'us',
        due_on: ref_date + 2.days, remind_days: [2], amount: 5500, currency: 'KZT', recurrence: 'yearly'
      )

      with_modified_env(
        'OWNER_FINANCE_USER_ID' => owner.id.to_s,
        'OWNER_FINANCE_WORKSPACE_ACCOUNT_ID' => exclusive_owner_account.id.to_s
      ) do
        res = OwnerFinance::DeadlineReminderService.new(reference_date: ref_date).perform
        expect(res[:reminded_count]).to eq(1)
        task = Crm::Task.find(res[:items].first[:crm_task_id])
        expect(task.account_id).to eq(exclusive_owner_account.id)
        expect(task.task_type_id).to be_present
        expect(task.activity_type).to eq('task')
        expect(dl.reload.last_reminded_on).to eq(ref_date)
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
      expect(dash[:transactions_total_count]).to eq(3)
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

  describe 'P1-2 & P2-2: 1C:Fresh same-day payment claiming, curated merchant preservation, transfers, and Contract bounds' do
    it 'claims matched supabase row without colliding on a 2nd same-day 99 000 KZT payment and preserves curated merchant' do
      existing = OwnerFinance::TransactionRecord.create!(
        occurred_on: Date.new(2026, 10, 25), direction: 'income', pnl_treatment: 'pnl',
        official_status: 'official_1c', review_status: 'confirmed',
        amount: 99_000, currency: 'KZT', category: 'client_subscription',
        merchant: 'МЦ Алия', external_source_key: 'supabase:tx:501'
      )

      incoming_docs = [
        {
          'Ref_Key' => 'doc-111', 'Date' => '2026-10-25T10:00:00',
          'СуммаДокумента' => 99_000, 'Номер' => '101', 'НазначениеПлатежа' => 'Оплата за OneLink'
        },
        {
          'Ref_Key' => 'doc-222', 'Date' => '2026-10-25T15:30:00',
          'СуммаДокумента' => 99_000, 'Номер' => '102', 'НазначениеПлатежа' => 'Оплата по счёту №18'
        }
      ]

      svc = OwnerFinance::OnecFreshSyncService.new(days_back: 10)
      allow(svc).to receive(:resolve_credentials).and_return({ base_url: 'https://1cfresh.kz/test', user: 'u', password: 'p' })
      allow(svc).to receive(:fetch_odata).and_return(incoming_docs, [])

      res = svc.perform
      expect(res[:transactions_upserted]).to eq(2)
      expect(existing.reload.external_source_key).to eq('1cfresh:income:doc-111')
      expect(existing.merchant).to eq('МЦ Алия')
      expect(existing.metadata['previous_external_source_key']).to eq('supabase:tx:501')

      day_income = OwnerFinance::TransactionRecord.where(direction: 'income', occurred_on: Date.new(2026, 10, 25))
      expect(day_income.sum(:amount_kzt)).to eq(BigDecimal(198_000))
    end

    it 'marks outgoing 1C transfers to own card as transfer / non_pnl' do
      outgoing_docs = [
        {
          'Ref_Key' => 'out-333', 'Date' => '2026-10-25T17:00:00',
          'СуммаДокумента' => 250_000, 'Номер' => '55',
          'НазначениеПлатежа' => 'Перевод собственных средств на карту Kaspi Gold'
        }
      ]

      svc = OwnerFinance::OnecFreshSyncService.new(days_back: 10)
      allow(svc).to receive(:resolve_credentials).and_return({ base_url: 'https://1cfresh.kz/test', user: 'u', password: 'p' })
      allow(svc).to receive(:fetch_odata).and_return([], outgoing_docs)
      svc.perform

      transfer_tx = OwnerFinance::TransactionRecord.find_by!(external_source_key: '1cfresh:expense:out-333')
      expect(transfer_tx.direction).to eq('transfer')
      expect(transfer_tx.pnl_treatment).to eq('non_pnl')
      expect(transfer_tx.category).to eq('accountable_transfer')
    end

    it 'validates Contract monthly_amount, medelement_commission_rate (0..1), and billing_day (1..31)' do
      invalid_rate = OwnerFinance::Contract.new(
        client_name: 'Клиника Тест', title: 'Договор №1', status: 'active',
        tariff_code: 'text_voice_99k', monthly_amount: 99_000, medelement_commission_rate: 30
      )
      expect(invalid_rate).not_to be_valid
      expect(invalid_rate.errors[:medelement_commission_rate]).to be_present

      neg_amount = OwnerFinance::Contract.new(
        client_name: 'Клиника Тест', title: 'Договор №2', status: 'active',
        tariff_code: 'text_voice_99k', monthly_amount: -1, billing_day: 35
      )
      expect(neg_amount).not_to be_valid
      expect(neg_amount.errors[:monthly_amount]).to be_present
      expect(neg_amount.errors[:billing_day]).to be_present
    end
  end
end
