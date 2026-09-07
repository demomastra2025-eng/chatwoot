class CreateCrmStageVisits < ActiveRecord::Migration[7.1]
  def up
    create_stage_visits
    add_stage_visit_invariants
    backfill_active_stage_visits
  end

  def down
    drop_table :crm_stage_visits
  end

  private

  def create_stage_visits
    create_table :crm_stage_visits do |t|
      t.references :account, null: false, foreign_key: true
      t.references :deal, null: false, foreign_key: { to_table: :crm_deals }
      t.references :pipeline, null: false, foreign_key: { to_table: :crm_pipelines }
      t.references :stage, null: false, foreign_key: { to_table: :crm_stages }
      t.datetime :entered_at, null: false
      t.datetime :exited_at
      t.boolean :estimated, null: false, default: false
      t.datetime :reliable_since, null: false
      t.string :pipeline_name, null: false
      t.string :stage_name, null: false
      t.string :stage_outcome, null: false
      t.uuid :correlation_id, null: false
      t.timestamps
    end
  end

  def add_stage_visit_invariants
    add_index :crm_stage_visits,
              :deal_id,
              unique: true,
              where: 'exited_at IS NULL',
              name: 'index_crm_stage_visits_on_active_deal'
    add_index :crm_stage_visits, %i[account_id entered_at]
    add_index :crm_stage_visits, :correlation_id
    add_check_constraint :crm_stage_visits,
                         'exited_at IS NULL OR exited_at >= entered_at',
                         name: 'crm_stage_visits_valid_interval'
  end

  def backfill_active_stage_visits
    backfill_time = connection.quote(Time.current)
    result = execute(stage_visit_backfill_sql(backfill_time))
    say "Created #{result.cmd_tuples} estimated active stage visits; durations are reliable since #{backfill_time}"
  end

  def stage_visit_backfill_sql(backfill_time)
    <<~SQL.squish
      INSERT INTO crm_stage_visits (
        account_id, deal_id, pipeline_id, stage_id, entered_at, estimated,
        reliable_since, pipeline_name, stage_name, stage_outcome,
        correlation_id, created_at, updated_at
      )
      SELECT
        deals.account_id, deals.id, deals.pipeline_id, deals.stage_id,
        #{backfill_time}, TRUE, #{backfill_time}, pipelines.name, stages.name,
        stages.outcome, gen_random_uuid(), #{backfill_time}, #{backfill_time}
      FROM crm_deals deals
      INNER JOIN crm_pipelines pipelines ON pipelines.id = deals.pipeline_id
      INNER JOIN crm_stages stages ON stages.id = deals.stage_id
      WHERE NOT EXISTS (
        SELECT 1 FROM crm_stage_visits visits
        WHERE visits.deal_id = deals.id AND visits.exited_at IS NULL
      )
    SQL
  end
end
