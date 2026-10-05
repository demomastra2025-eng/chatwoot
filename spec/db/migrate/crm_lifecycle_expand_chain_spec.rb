require 'rails_helper'

# The whole series, 20261004120000 .. 20261004193200, against the PROD shape (the CRM objects reverted) and against the
# final schema (what DEV looks like after the earlier single-transaction version of 20261004120000).
RSpec.describe 'CRM lifecycle expand migration series', :crm_lifecycle_ddl do # rubocop:disable RSpec/DescribeClass
  let(:chain) { CrmLifecycleMigrationHelper::CHAIN }

  def legacy_event
    account = create(:account)
    db.execute(<<~SQL.squish)
      INSERT INTO crm_events (account_id, eventable_type, eventable_id, event_type, meta, created_at)
      VALUES (#{account.id}, 'Crm::Deal', 1, 'deal_updated', '{}', now() - interval '1 hour')
    SQL
  end

  def live_data
    [db.select_rows('SELECT id, schedule_timezone, task_type_id, context_kind FROM crm_tasks ORDER BY id'),
     db.select_rows('SELECT id, published_at FROM crm_events ORDER BY id')]
  end

  it 'turns the PROD shape into exactly the schema of db/schema.rb' do
    expected = crm_schema_snapshot
    create(:crm_task)
    revert_to_prod_shape!
    expect(crm_schema_snapshot).not_to eq(expected)
    legacy_event

    run_chain(*chain)
    rebuilt = crm_schema_snapshot

    %i[columns indexes constraints].each do |part|
      expect(rebuilt[part] - expected[part]).to eq([])
      expect(expected[part] - rebuilt[part]).to eq([])
    end
    expect(rebuilt).to eq(expected)
    expect(invalid_indexes).to be_empty
    expect(unvalidated_constraints).to be_empty
  end

  it 'changes nothing when the whole series runs a second time' do
    create(:crm_task)
    revert_to_prod_shape!
    legacy_event
    run_chain(*chain)
    snapshot = crm_schema_snapshot
    data = live_data

    run_chain(*chain, times: 2)

    expect(crm_schema_snapshot).to eq(snapshot)
    expect(live_data).to eq(data)
  end

  it 'converges on the final schema when the series runs on top of it' do
    snapshot = crm_schema_snapshot
    run_chain(*chain, times: 2)

    expect(crm_schema_snapshot).to eq(snapshot)
  end

  it 'only adds objects to the PROD shape: no existing column, index or constraint changes' do
    revert_to_prod_shape!
    before = crm_schema_snapshot
    run_chain(*chain)
    after = crm_schema_snapshot

    expect(before[:columns] - after[:columns]).to be_empty
    expect(before[:indexes] - after[:indexes]).to be_empty
    expect(before[:constraints] - after[:constraints]).to be_empty
  end
end
