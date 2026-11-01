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
    let(:todo_status) { Crm::TaskStatus.find_by!(account_id: workspace.id, code: 'todo') }
    let(:task_type) { Crm::TaskType.find_by!(account_id: workspace.id, code: 'task') }
    let(:env_vars) { { 'OWNER_FINANCE_USER_ID' => owner.id.to_s, 'OWNER_FINANCE_WORKSPACE_ACCOUNT_ID' => workspace.id.to_s } }

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

    def build_workspace_task(**overrides)
      Crm::Task.create!(
        {
          account_id: workspace.id, status_id: todo_status.id, task_type_id: task_type.id,
          activity_type: 'task', assignee_id: owner.id, creator_id: owner.id, priority: 'medium',
          all_day: true, due_on: Date.new(2026, 10, 31), title: 'Тестовая задача срока'
        }.merge(overrides)
      )
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

      with_modified_env(env_vars) do
        first_run = OwnerFinance::DeadlineReminderService.new(reference_date: ref_date).perform
        expect(first_run[:items].map { |i| i[:deadline_id] }).to contain_exactly(dl_7d.id, dl_0d.id)
        expect(Crm::Task.where(account_id: workspace.id, assignee_id: owner.id).count).to eq(2)

        second_run = OwnerFinance::DeadlineReminderService.new(reference_date: ref_date).perform
        expect(second_run[:reminded_count]).to eq(0)
      end
    end

    it 'keeps strictly 1 Crm::Task per deadline cycle across [7, 3, 2, 0] and overdue days by updating in place' do
      start_date = Date.new(2026, 11, 1)
      due_date = start_date + 7.days
      in_progress_status = Crm::TaskStatus.create!(
        account_id: workspace.id, code: 'in_progress', name: 'В работе', category: 'open', position: 2
      )
      deadline = OwnerFinance::Deadline.create!(
        title: 'Сервер АТС Wazo', category: 'hosting', payer_mode: 'us',
        due_on: due_date, amount: 23_040, currency: 'KZT', recurrence: 'monthly'
      )

      with_modified_env(env_vars) do
        r7 = OwnerFinance::DeadlineReminderService.new(reference_date: start_date).perform
        task = Crm::Task.find(r7[:items].first[:crm_task_id])
        expect(task).to have_attributes(
          priority: 'medium',
          idempotency_key: "owner_finance:deadline:#{deadline.id}:#{due_date.iso8601}"
        )

        task.update!(status_id: in_progress_status.id)
        days = [start_date + 4.days, start_date + 5.days, due_date, due_date + 1.day, due_date + 10.days]
        returned_ids = days.map { |day| OwnerFinance::DeadlineReminderService.new(reference_date: day).perform[:items].first[:crm_task_id] }

        expect(returned_ids.uniq).to eq([task.id])
        expect(Crm::Task.where(account_id: workspace.id).count).to eq(1)
        expect(task.reload).to have_attributes(
          priority: 'high', status_id: in_progress_status.id, due_on: due_date + 10.days
        )
        expect(task.title).to start_with('[Просрочено 10 дн.] Сервер АТС Wazo')
      end
    end

    it 'does not spawn duplicate overdue tasks after a legacy task is cancelled/archived, until next cycle' do
      due_date = Date.new(2026, 9, 10)
      deadline = OwnerFinance::Deadline.create!(
        title: 'Hoster.KZ Cloud', category: 'hosting', payer_mode: 'us',
        due_on: due_date, amount: 23_040, currency: 'KZT', recurrence: 'monthly'
      )
      legacy_key = "owner_finance:deadline:#{deadline.id}:#{due_date.iso8601}:d-51"
      build_workspace_task(
        priority: 'high', idempotency_key: legacy_key, external_ref: legacy_key,
        title: '[Просрочено 51 дн.] Hoster.KZ Cloud',
        cancelled_at: Time.current, cancellation_reason: 'Дубль', archived_at: Time.current
      )

      with_modified_env(env_vars) do
        next_day_res = OwnerFinance::DeadlineReminderService.new(reference_date: Date.new(2026, 11, 1)).perform
        expect(next_day_res[:reminded_count]).to eq(0)
        expect(Crm::Task.where(account_id: workspace.id).count).to eq(1)

        deadline.advance_or_complete!(reference_date: Date.new(2026, 11, 1))
        expect(deadline.reload.due_on).to eq(Date.new(2026, 11, 10))

        new_cycle_res = OwnerFinance::DeadlineReminderService.new(reference_date: Date.new(2026, 11, 3)).perform
        expect(new_cycle_res[:reminded_count]).to eq(1)
        expect(Crm::Task.where(account_id: workspace.id).count).to eq(2)
      end
    end

    it 'migrates newest open legacy task without resurrecting older open :dN duplicates after completion' do
      due_date = Date.new(2026, 11, 5)
      deadline = OwnerFinance::Deadline.create!(
        title: 'Домен one-link.kz', category: 'own_domain', payer_mode: 'us',
        due_on: due_date, amount: 6500, currency: 'KZT', recurrence: 'yearly'
      )
      key = "owner_finance:deadline:#{deadline.id}:#{due_date.iso8601}"
      older_dup = build_workspace_task(due_on: Date.new(2026, 11, 2), idempotency_key: "#{key}:d3", external_ref: "#{key}:d3")
      newest_open = build_workspace_task(due_on: Date.new(2026, 11, 3), idempotency_key: "#{key}:d2", external_ref: 'CUSTOM-REF-1')

      with_modified_env(env_vars) do
        res = OwnerFinance::DeadlineReminderService.new(reference_date: due_date).perform
        expect(res[:items].first[:crm_task_id]).to eq(newest_open.id)
        expect(newest_open.reload).to have_attributes(idempotency_key: key, external_ref: 'CUSTOM-REF-1', due_on: due_date)

        newest_open.update!(completed_at: Time.current, completed_by_id: owner.id)
        overdue_res = OwnerFinance::DeadlineReminderService.new(reference_date: due_date + 1.day).perform

        expect(overdue_res[:reminded_count]).to eq(0)
        expect(older_dup.reload).to have_attributes(idempotency_key: "#{key}:d3", due_on: Date.new(2026, 11, 2))
        expect(Crm::Task.where(account_id: workspace.id).count).to eq(2)
      end
    end

    it 'recognizes external_ref-only matches without RecordInvalid collision when completed' do
      due_date = Date.new(2026, 11, 5)
      deadline = OwnerFinance::Deadline.create!(
        title: 'Продление SSL', category: 'hosting', payer_mode: 'us',
        due_on: due_date, amount: 12_000, currency: 'KZT', recurrence: 'yearly'
      )
      key = "owner_finance:deadline:#{deadline.id}:#{due_date.iso8601}"
      build_workspace_task(idempotency_key: nil, external_ref: key, completed_at: Time.current, completed_by_id: owner.id)

      with_modified_env(env_vars) do
        res = OwnerFinance::DeadlineReminderService.new(reference_date: due_date).perform
        expect(res[:reminded_count]).to eq(0)
        expect(Crm::Task.where(account_id: workspace.id).count).to eq(1)
      end
    end

    it 'preserves moved-forward due_on, timed due_at schedule, elevated urgent priority, and custom external_ref' do
      start_date = Date.new(2026, 11, 1)
      due_date = start_date + 7.days
      OwnerFinance::Deadline.create!(
        title: 'Сервер KZ Almaty', category: 'hosting', payer_mode: 'us',
        due_on: due_date, amount: 35_000, currency: 'KZT', recurrence: 'monthly'
      )

      with_modified_env(env_vars) do
        first = OwnerFinance::DeadlineReminderService.new(reference_date: start_date).perform
        task = Crm::Task.find(first[:items].first[:crm_task_id])
        task.update!(priority: 'urgent', external_ref: 'INV-77', due_on: start_date + 6.days)

        OwnerFinance::DeadlineReminderService.new(reference_date: start_date + 4.days).perform
        expect(task.reload).to have_attributes(priority: 'urgent', external_ref: 'INV-77', due_on: start_date + 6.days)

        scheduled_time = Time.zone.parse('2026-11-08 14:30:00')
        task.update!(all_day: false, due_on: nil, due_at: scheduled_time)
        OwnerFinance::DeadlineReminderService.new(reference_date: due_date).perform
        expect(task.reload).to have_attributes(all_day: false, due_on: nil, priority: 'urgent')
        expect(task.due_at).to be_within(1.second).of(scheduled_time)
      end
    end

    it 'recovers from StaleObjectError on concurrent completion and uniqueness RecordInvalid race on create' do
      due_date = Date.new(2026, 11, 5)
      dl_create_race = OwnerFinance::Deadline.create!(
        title: 'Гонка создания', category: 'hosting', payer_mode: 'us', due_on: due_date, amount: 1000, currency: 'KZT'
      )
      dl_stale_race = OwnerFinance::Deadline.create!(
        title: 'Гонка обновления', category: 'hosting', payer_mode: 'us', due_on: due_date, amount: 2000, currency: 'KZT'
      )
      key_create = "owner_finance:deadline:#{dl_create_race.id}:#{due_date.iso8601}"
      key_stale = "owner_finance:deadline:#{dl_stale_race.id}:#{due_date.iso8601}"
      stale_task = build_workspace_task(due_on: Date.new(2026, 11, 2), idempotency_key: key_stale, external_ref: key_stale)

      injected_create = false
      allow(Crm::Task).to receive(:create!).and_wrap_original do |orig, attrs|
        if !injected_create && attrs[:idempotency_key] == key_create
          injected_create = true
          orig.call(attrs)
        end
        orig.call(attrs)
      end

      service = OwnerFinance::DeadlineReminderService.new(reference_date: due_date)
      injected_stale = false
      allow(service).to receive(:update_open_task!).and_wrap_original do |orig, task, *rest|
        if !injected_stale && task.id == stale_task.id
          injected_stale = true
          Crm::Task.find(task.id).update!(completed_at: Time.current, completed_by_id: owner.id)
        end
        orig.call(task, *rest)
      end

      with_modified_env(env_vars) do
        res = service.perform
        expect(res[:items].map { |i| i[:deadline_id] }).to eq([dl_create_race.id])
        expect(Crm::Task.where(account_id: workspace.id, idempotency_key: key_create).count).to eq(1)
        expect(stale_task.reload.completed_at).to be_present
      end
    end
  end
end
