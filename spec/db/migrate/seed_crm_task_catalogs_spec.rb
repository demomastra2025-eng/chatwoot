require 'rails_helper'
require Rails.root.join('db/migrate/20261004120250_seed_crm_task_catalogs')

RSpec.describe SeedCrmTaskCatalogs, :crm_lifecycle_ddl do
  let(:accounts) { create_list(:account, 3) }

  before do
    accounts.each { |account| create(:crm_task, account: account) }
    revert_to_prod_shape!
    run_chain(:columns, :tables, :constraints)
  end

  def codes(account, table)
    db.select_values("SELECT code FROM #{table} WHERE account_id = #{account.id} ORDER BY position, code")
  end

  it 'seeds the system codes, one default type and one default outcome per type, for accounts that have tasks' do
    run_migration(:catalogs)

    accounts.each do |account|
      expect(codes(account, 'crm_task_types')).to eq(%w[task call meeting message touch])
      expect(db.select_value("SELECT count(*) FROM crm_task_outcomes WHERE account_id = #{account.id}")).to eq(20)
      expect(db.select_value("SELECT count(*) FROM crm_task_types WHERE account_id = #{account.id} AND \"default\"")).to eq(1)
      expect(db.select_value(<<~SQL.squish)).to eq(5)
        SELECT count(*) FROM crm_task_outcomes WHERE account_id = #{account.id} AND "default"
      SQL
    end
    expect(db.select_value("SELECT count(*) FROM crm_task_outcomes WHERE code = 'not_done' AND requires_note")).to eq(15)
  end

  it 'writes no user-visible English text: every name is a system code' do
    run_migration(:catalogs)

    names = db.select_values('SELECT name FROM crm_task_types UNION ALL SELECT name FROM crm_task_outcomes')
    expect(names).not_to be_empty
    expect(names).to all(match(/\A[a-z_]+\z/))
    expect(names.join(' ')).not_to match(/Touch|Task|Call|Meeting|Message|No answer|Completed/)
  end

  it 'seeds only accounts that have none, so a removed or renamed type stays as the administrator left it' do
    custom = accounts.first
    db.execute(<<~SQL.squish)
      INSERT INTO crm_task_types (account_id, name, code, icon, position, active, "default", created_at, updated_at)
      VALUES (#{custom.id}, 'Custom', 'task', 'i-lucide-list-todo', 1, TRUE, TRUE, now(), now())
    SQL

    run_migration(:catalogs)

    expect(codes(custom, 'crm_task_types')).to eq(['task'])
    expect(db.select_value("SELECT name FROM crm_task_types WHERE account_id = #{custom.id}")).to eq('Custom')
    expect(codes(accounts.last, 'crm_task_types').size).to eq(5)
  end

  it 'is idempotent and leaves later changes alone' do
    run_migration(:catalogs)
    account = accounts.last
    db.execute("UPDATE crm_task_types SET name = 'Renamed' WHERE code = 'touch' AND account_id = #{account.id}")
    db.execute(<<~SQL.squish)
      DELETE FROM crm_task_outcomes WHERE task_type_id IN
        (SELECT id FROM crm_task_types WHERE code = 'meeting' AND account_id = #{account.id})
    SQL
    db.execute("DELETE FROM crm_task_types WHERE code = 'meeting' AND account_id = #{account.id}")
    before = db.select_rows('SELECT id, account_id, code, name FROM crm_task_types ORDER BY id')

    run_migration(:catalogs, times: 2)

    expect(db.select_rows('SELECT id, account_id, code, name FROM crm_task_types ORDER BY id')).to eq(before)
  end

  it 'works through accounts in slices' do
    stub_const("#{described_class}::ACCOUNT_SLICE", 2)

    run_migration(:catalogs)

    expect(db.select_value('SELECT count(DISTINCT account_id) FROM crm_task_types')).to eq(3)
  end

  it 'does not touch accounts without tasks' do
    idle = create(:account)

    run_migration(:catalogs)

    expect(codes(idle, 'crm_task_types')).to be_empty
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
