# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'OwnerFinance Services', type: :model do
  describe 'StatementImportService and PersonalHideService' do
    let(:sample_csv) do
      <<~CSV
        date,amount,currency,merchant,description
        2026-10-25,-12500.00,KZT,Contabo GmbH,Cloud VPS 20 EU
        2026-10-26,-4850.00,KZT,Magnum Cash & Carry,Покупка продуктов
        2026-10-27,-3100.00,KZT,Magnum Cash & Carry,Покупка вода и кофе
        2026-10-28,250000.00,KZT,Поступление со своего счета в Kaspi Pay,Перевод собственных средств
      CSV
    end

    it 'classifies business vendors, accountable transfers, and deduplicates re-imports' do
      res = OwnerFinance::StatementImportService.new(filename: 'kaspi_oct.csv', content: sample_csv).perform

      expect(res).to include(total_parsed: 4, imported_business: 2, queued_for_review: 2, skipped_duplicates: 0)
      expect(OwnerFinance::TransactionRecord.find_by(category: 'servers_and_cloud')&.review_status).to eq('confirmed')
      expect(OwnerFinance::TransactionRecord.find_by(category: 'accountable_transfer')&.pnl_treatment).to eq('non_pnl')

      dup_res = OwnerFinance::StatementImportService.new(filename: 'kaspi_oct.csv', content: sample_csv).perform
      expect(dup_res).to include(skipped_duplicates: 4, imported_business: 0, queued_for_review: 0)
    end

    it 'wipes personal transactions into SHA-256 tombstones and auto-hides future purchases of same store' do
      OwnerFinance::StatementImportService.new(filename: 'kaspi_oct.csv', content: sample_csv).perform
      magnum_rows = OwnerFinance::TransactionRecord.needs_review.order(:id)

      hide_res = OwnerFinance::PersonalHideService.new(transaction: magnum_rows.first, hide_merchant_always: true).perform
      expect(hide_res[:hidden_count]).to eq(2)
      expect(OwnerFinance::TransactionRecord.where('merchant ILIKE ?', '%Magnum%')).to be_empty
      expect(OwnerFinance::PersonalTombstone.count).to eq(2)

      next_csv = "date,amount,currency,merchant,description\n2026-11-02,-7200.00,KZT,Magnum Cash & Carry,Личная покупка\n"
      next_res = OwnerFinance::StatementImportService.new(filename: 'kaspi_nov.csv', content: next_csv).perform
      expect(next_res).to include(auto_hidden_personal: 1, queued_for_review: 0)
      expect(OwnerFinance::TransactionRecord.where('merchant ILIKE ?', '%Magnum%')).to be_empty
    end
  end

  describe 'DeadlineReminderService ([7, 3, 2, 1, 0] days into Crm::Task)' do
    let(:owner) { create(:user) }
    let(:workspace) { create(:account, name: 'Личный кабинет владельца') }

    before do
      create(:account_user, account: workspace, user: owner, role: :administrator)
      Crm::TaskStatus.find_or_create_by!(account_id: workspace.id, code: 'todo') do |st|
        st.name = 'К выполнению'
        st.category = 'open'
        st.position = 1
      end
      Crm::TaskType.find_or_create_by!(account_id: workspace.id, code: 'task') do |tp|
        tp.name = 'Задача'
        tp.position = 1
      end
    end

    it 'creates idempotent Crm::Tasks only on configured reminder offsets' do
      ref_date = Date.new(2026, 10, 30)
      dl_7d = OwnerFinance::Deadline.create!(
        title: 'Сервер Contabo PROD', category: 'hosting', payer_mode: 'us',
        due_on: ref_date + 7.days, amount: 45_000, currency: 'KZT', recurrence: 'monthly'
      )
      OwnerFinance::Deadline.create!(
        title: 'Домен через 5 дн.', category: 'own_domain', payer_mode: 'us',
        due_on: ref_date + 5.days, amount: 5500, currency: 'KZT', recurrence: 'yearly'
      )
      dl_0d = OwnerFinance::Deadline.create!(
        title: 'Домен клиента odcw.kz', category: 'client_domain', payer_mode: 'rebill_client',
        due_on: ref_date, amount: 6500, currency: 'KZT', recurrence: 'yearly'
      )

      with_modified_env('OWNER_FINANCE_USER_ID' => owner.id.to_s, 'OWNER_FINANCE_WORKSPACE_ACCOUNT_ID' => workspace.id.to_s) do
        first_run = OwnerFinance::DeadlineReminderService.new(reference_date: ref_date).perform
        expect(first_run[:items].map { |i| i[:deadline_id] }).to contain_exactly(dl_7d.id, dl_0d.id)
        expect(Crm::Task.where(account_id: workspace.id, assignee_id: owner.id).count).to eq(2)

        second_run = OwnerFinance::DeadlineReminderService.new(reference_date: ref_date).perform
        expect(second_run[:reminded_count]).to eq(0)
      end
    end
  end
end
