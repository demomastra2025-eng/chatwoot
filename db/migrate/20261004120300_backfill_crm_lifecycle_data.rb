class BackfillCrmLifecycleData < ActiveRecord::Migration[7.1]
  # Step 4 (backfill) of the CRM lifecycle expand: data backfills in id-range batches. Every statement is its own short
  # autocommit transaction (row locks only), so no table stays locked and no statement approaches the request timeout
  # however large the tables are. Every statement also carries a "not filled yet" guard, so a re-run (or a database
  # that already went through the older single-transaction version of 20261004120000) never overwrites a value that
  # live code has written since:
  # * schedule timezones change only on rows that still hold the column default and were created before the column
  #   existed (the cutover that 20261004120000 persisted), only where the account's own zone differs, and only once:
  #   a completion marker stops a later run from reverting a zone someone has chosen since;
  # * published_at is set only on events created before that cutover; 20261004193200 closes the gap that opens while
  #   the migrations run;
  # * task context and catalog references are filled only where they are still empty;
  # * stage visits are estimated only for deals that have no visit at all.
  disable_ddl_transaction!

  BATCH_SIZE = 5_000
  BATCH_PAUSE = 0.05
  DEFAULT_TIMEZONE = 'Asia/Almaty'.freeze
  EPOCH = Time.at(0).utc.freeze
  TASK_CUTOVER_KEY = 'crm_tasks_schedule_cutover'.freeze
  TASK_BACKFILLED_KEY = 'crm_tasks_schedule_backfilled'.freeze
  EVENT_CUTOVER_KEY = 'crm_events_envelope_cutover'.freeze

  def up
    backfill_schedule_timezones
    backfill_context_kind
    backfill_task_catalog_references
    backfill_published_events
    backfill_stage_visits
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def each_id_range(table)
    min, max = select_rows("SELECT MIN(id), MAX(id) FROM #{table}").first.map(&:to_i)
    return if max.zero?

    (min..max).step(BATCH_SIZE) do |low|
      yield low, [low + BATCH_SIZE - 1, max].min
      sleep(BATCH_PAUSE)
    end
  end

  def stored_value(key)
    select_value("SELECT value FROM ar_internal_metadata WHERE key = #{connection.quote(key)}")
  end

  def stored_cutover(key)
    value = stored_value(key)
    value.present? ? Time.iso8601(value) : EPOCH
  end

  def store_value(key, value)
    execute <<~SQL.squish
      INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
      VALUES (#{connection.quote(key)}, #{connection.quote(value)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (key) DO NOTHING
    SQL
  end

  def backfill_schedule_timezones
    cutover = stored_cutover(TASK_CUTOVER_KEY)
    return unless cutover > EPOCH
    return if stored_value(TASK_BACKFILLED_KEY)

    store_zones_on_legacy_tasks(cutover, account_timezones)
    store_value(TASK_BACKFILLED_KEY, Time.current.utc.iso8601(6))
  end

  def store_zones_on_legacy_tasks(cutover, zones)
    return if zones.empty?

    values = zones.map { |account_id, zone| "(#{account_id.to_i}, #{connection.quote(zone)})" }.join(', ')
    each_id_range(:crm_tasks) do |low, high|
      execute <<~SQL.squish
        UPDATE crm_tasks SET schedule_timezone = zones.zone
        FROM (VALUES #{values}) AS zones(account_id, zone)
        WHERE crm_tasks.id BETWEEN #{low} AND #{high}
          AND crm_tasks.account_id = zones.account_id
          AND crm_tasks.schedule_timezone = #{connection.quote(DEFAULT_TIMEZONE)}
          AND crm_tasks.created_at <= #{connection.quote(cutover)}
      SQL
    end
  end

  # Only accounts whose configured reporting zone differs from the column default need rows rewritten.
  def account_timezones
    rows = select_rows(<<~SQL.squish)
      SELECT accounts.id, accounts.settings ->> 'reporting_timezone'
      FROM accounts
      WHERE EXISTS (SELECT 1 FROM crm_tasks WHERE crm_tasks.account_id = accounts.id)
    SQL
    rows.filter_map do |account_id, reporting_timezone|
      zone = timezone_for_reporting_setting(reporting_timezone)
      [account_id, zone] unless zone == DEFAULT_TIMEZONE
    end
  end

  def timezone_for_reporting_setting(reporting_timezone)
    return DEFAULT_TIMEZONE if reporting_timezone.blank?

    ActiveSupport::TimeZone[reporting_timezone]&.tzinfo&.identifier.presence || DEFAULT_TIMEZONE
  rescue ArgumentError
    DEFAULT_TIMEZONE
  end

  def backfill_context_kind
    each_id_range(:crm_tasks) do |low, high|
      execute <<~SQL.squish
        UPDATE crm_tasks
        SET context_kind = CASE WHEN deal_id IS NULL THEN 'personal' ELSE 'sales' END
        WHERE context_kind IS NULL AND id BETWEEN #{low} AND #{high}
      SQL
    end
  end

  def backfill_task_catalog_references
    each_id_range(:crm_tasks) do |low, high|
      execute <<~SQL.squish
        UPDATE crm_tasks SET task_type_id = crm_task_types.id
        FROM crm_task_types
        WHERE crm_task_types.account_id = crm_tasks.account_id
          AND crm_task_types.code = crm_tasks.activity_type
          AND crm_tasks.task_type_id IS NULL
          AND crm_tasks.id BETWEEN #{low} AND #{high}
      SQL
      execute <<~SQL.squish
        UPDATE crm_tasks SET task_outcome_id = crm_task_outcomes.id
        FROM crm_task_outcomes
        WHERE crm_task_outcomes.task_type_id = crm_tasks.task_type_id
          AND crm_task_outcomes.account_id = crm_tasks.account_id
          AND crm_task_outcomes.code = crm_tasks.outcome
          AND crm_tasks.task_outcome_id IS NULL
          AND crm_tasks.id BETWEEN #{low} AND #{high}
      SQL
    end
  end

  def backfill_published_events
    cutover = stored_cutover(EVENT_CUTOVER_KEY)
    return unless cutover > EPOCH

    each_id_range(:crm_events) do |low, high|
      execute <<~SQL.squish
        UPDATE crm_events SET published_at = created_at
        WHERE published_at IS NULL AND created_at <= #{connection.quote(cutover)}
          AND id BETWEEN #{low} AND #{high}
      SQL
    end
  end

  def backfill_stage_visits
    now = connection.quote(Time.current)
    each_id_range(:crm_deals) do |low, high|
      execute <<~SQL.squish
        INSERT INTO crm_stage_visits (
          account_id, deal_id, pipeline_id, stage_id, entered_at, estimated, reliable_since,
          pipeline_name, stage_name, stage_outcome, correlation_id, created_at, updated_at
        )
        SELECT deals.account_id, deals.id, deals.pipeline_id, deals.stage_id, #{now}, TRUE, #{now},
               pipelines.name, stages.name, stages.outcome, gen_random_uuid(), #{now}, #{now}
        FROM crm_deals deals
        INNER JOIN crm_pipelines pipelines ON pipelines.id = deals.pipeline_id
        INNER JOIN crm_stages stages ON stages.id = deals.stage_id
        WHERE deals.id BETWEEN #{low} AND #{high}
          AND NOT EXISTS (SELECT 1 FROM crm_stage_visits visits WHERE visits.deal_id = deals.id)
        ON CONFLICT DO NOTHING
      SQL
    end
  end
end
