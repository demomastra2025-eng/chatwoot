require 'rails_helper'
require Rails.root.join('db/migrate/20261004120300_backfill_crm_lifecycle_data')

RSpec.describe BackfillCrmLifecycleData, :crm_lifecycle_ddl do
  let(:zone_cases) do
    [
      [{}, 'Asia/Almaty'],
      [{ 'reporting_timezone' => nil }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => '' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => '   ' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => 'Not/A_Real_Zone' }, 'Asia/Almaty'],
      [{ 'reporting_timezone' => 'Europe/Berlin' }, 'Europe/Berlin'],
      [{ 'reporting_timezone' => 'Eastern Time (US & Canada)' }, 'America/New_York']
    ]
  end
  let(:start_at) { Time.utc(2025, 2, 3, 10, 15) }
  let(:due_at) { Time.utc(2025, 2, 3, 11, 45) }

  # One account per timezone case with one legacy task each; the first one is a sales task (it has a deal).
  let!(:entries) do
    zone_cases.map.with_index do |(settings, zone), index|
      account = create(:account)
      deal = create(:crm_deal, account: account) if index.zero?
      task = create(:crm_task, account: account, deal: deal, activity_type: index.zero? ? 'call' : 'task',
                               outcome: 'completed', start_at: start_at, due_at: due_at)
      account.update_columns(settings: settings) # rubocop:disable Rails/SkipsModelValidations -- recreate stored legacy settings rejected by current validation
      { task: task, zone: zone, account: account, deal: deal }
    end
  end
  let(:account) { entries.first[:account] }
  let(:berlin_task) { entries[5][:task] }
  let(:state) { {} }

  def insert_event(created_at:)
    db.select_value(<<~SQL.squish)
      INSERT INTO crm_events (account_id, eventable_type, eventable_id, event_type, meta, created_at)
      VALUES (#{account.id}, 'Crm::Deal', 1, 'deal_updated', '{}', #{db.quote(created_at)}) RETURNING id
    SQL
  end

  def task_row(task)
    db.select_one("SELECT * FROM crm_tasks WHERE id = #{task.id}")
  end

  def live_state
    [
      db.select_rows('SELECT id, schedule_timezone, all_day, due_on FROM crm_tasks ORDER BY id'),
      db.select_rows('SELECT id, published_at, publication_attempts FROM crm_events ORDER BY id'),
      db.select_rows('SELECT id, account_id, code, name FROM crm_task_types ORDER BY id'),
      db.select_rows('SELECT id, deal_id, exited_at FROM crm_stage_visits ORDER BY id')
    ]
  end

  # The PROD shape up to the backfill, with one event that predates the new columns.
  def migrate_legacy_database
    revert_to_prod_shape!
    run_chain(:columns, :tables, :constraints)
    state[:legacy_event] = insert_event(created_at: 1.hour.ago)
    run_chain(:catalogs, :backfill)
  end

  describe 'on a PROD-shaped database' do
    it 'fills task timezones, context and catalog references without touching task state' do
      migrate_legacy_database

      entries.each do |entry|
        expect(task_row(entry[:task])).to include(
          'schedule_timezone' => entry[:zone], 'outcome' => 'completed', 'all_day' => false, 'due_on' => nil,
          'start_at' => be_within(1.second).of(start_at), 'due_at' => be_within(1.second).of(due_at)
        )
      end
      sales = task_row(entries[0][:task])
      personal = task_row(entries[1][:task])
      expect([sales['context_kind'], personal['context_kind']]).to eq(%w[sales personal])
      expect(db.select_value("SELECT code FROM crm_task_types WHERE id = #{sales['task_type_id']}")).to eq('call')
      expect(sales['task_outcome_id']).to be_nil # 'completed' is not an outcome of a call
      expect(db.select_value("SELECT code FROM crm_task_outcomes WHERE id = #{personal['task_outcome_id']}"))
        .to eq('completed')
    end

    it 'marks events that existed when the column appeared as published and estimates one visit per deal' do
      migrate_legacy_database

      expect(db.select_value("SELECT published_at = created_at FROM crm_events WHERE id = #{state.fetch(:legacy_event)}")).to be(true)
      expect(db.select_rows("SELECT estimated, exited_at IS NULL FROM crm_stage_visits WHERE deal_id = #{entries[0][:deal].id}"))
        .to eq([[true, true]])
    end

    it 'does not overwrite live data when it runs again' do
      migrate_legacy_database
      db.execute(<<~SQL.squish)
        UPDATE crm_tasks SET all_day = TRUE, due_on = '2026-10-10', due_at = NULL, start_at = NULL,
          schedule_timezone = 'Asia/Tokyo' WHERE id = #{entries[1][:task].id}
      SQL
      db.execute("UPDATE crm_tasks SET schedule_timezone = 'Asia/Almaty' WHERE id = #{berlin_task.id}")
      live_event = insert_event(created_at: 1.hour.from_now)
      db.execute("UPDATE crm_events SET publication_attempts = 3, publication_error = 'boom' WHERE id = #{live_event}")
      db.execute("UPDATE crm_task_types SET name = 'Renamed' WHERE code = 'touch' AND account_id = #{account.id}")
      db.execute(<<~SQL.squish)
        DELETE FROM crm_task_outcomes WHERE task_type_id IN
          (SELECT id FROM crm_task_types WHERE code = 'meeting' AND account_id = #{account.id})
      SQL
      db.execute("DELETE FROM crm_task_types WHERE code = 'meeting' AND account_id = #{account.id}")
      db.execute("UPDATE crm_stage_visits SET exited_at = now() + interval '1 hour' WHERE deal_id = #{entries[0][:deal].id}")
      before = live_state

      run_chain(:catalogs, :backfill, times: 2)

      expect(live_state).to eq(before)
      expect(db.select_value("SELECT published_at FROM crm_events WHERE id = #{live_event}")).to be_nil
      expect(task_row(berlin_task)['schedule_timezone']).to eq('Asia/Almaty')
    end

    it 'covers every row when the table is larger than one batch' do
      stub_const("#{described_class}::BATCH_SIZE", 2)

      migrate_legacy_database

      expect(db.select_value('SELECT count(*) FROM crm_tasks WHERE context_kind IS NULL')).to eq(0)
      expect(db.select_value('SELECT count(*) FROM crm_tasks WHERE task_type_id IS NULL')).to eq(0)
      expect(task_row(berlin_task)['schedule_timezone']).to eq('Europe/Berlin')
      expect(task_row(entries[6][:task])['schedule_timezone']).to eq('America/New_York')
    end
  end

  describe 'on a database that already has the lifecycle columns (DEV, aset lineage)' do
    it 'treats every existing row as live: no timezone and no published mark' do
      db.execute("DELETE FROM ar_internal_metadata WHERE key LIKE 'crm_%'")
      db.execute("UPDATE crm_tasks SET schedule_timezone = 'Asia/Almaty' WHERE id = #{berlin_task.id}")
      pending_event = insert_event(created_at: 1.day.ago)

      run_migration(:backfill)

      expect(task_row(berlin_task)['schedule_timezone']).to eq('Asia/Almaty')
      expect(db.select_value("SELECT published_at FROM crm_events WHERE id = #{pending_event}")).to be_nil
    end
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
