class MarkLegacyCrmEventsPublished < ActiveRecord::Migration[7.1]
  # Final step of the CRM lifecycle expand: it closes the double-publication gap. The previous application dispatches a
  # CRM event synchronously when it is created and never sets published_at, so every event it writes while the migrations
  # run (after 20261004120000 added the column) would look unpublished to the new replay job and be sent a second time
  # right after the deploy. Running last, this marks everything created before the migration chain ends as published.
  # The boundary is persisted, so a re-run never moves it, and nothing is marked when the columns predate the chain
  # (DEV, aset lineage: no cutover was recorded, those events are live work) or when the new code is already
  # publishing events (an event created after the cutover carries published_at).
  disable_ddl_transaction!

  BATCH_SIZE = 5_000
  BATCH_PAUSE = 0.05
  EVENT_CUTOVER_KEY = 'crm_events_envelope_cutover'.freeze
  BASELINE_KEY = 'crm_events_legacy_publication_baseline'.freeze
  EPOCH = Time.at(0).utc.freeze

  def up
    baseline = publication_baseline
    return unless baseline > EPOCH

    min, max = select_rows('SELECT MIN(id), MAX(id) FROM crm_events WHERE published_at IS NULL').first.map(&:to_i)
    return if max.zero?

    (min..max).step(BATCH_SIZE) do |low|
      execute <<~SQL.squish
        UPDATE crm_events SET published_at = created_at
        WHERE published_at IS NULL AND created_at <= #{connection.quote(baseline)}
          AND id BETWEEN #{low} AND #{[low + BATCH_SIZE - 1, max].min}
      SQL
      sleep(BATCH_PAUSE)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'CRM lifecycle schema is additive; roll back application behavior without removing retained CRM data'
  end

  private

  def publication_baseline
    stored = stored_time(BASELINE_KEY)
    return stored if stored

    cutover = stored_time(EVENT_CUTOVER_KEY) || EPOCH
    baseline = cutover > EPOCH && !new_code_publishing?(cutover) ? Time.current : cutover
    execute <<~SQL.squish
      INSERT INTO ar_internal_metadata (key, value, created_at, updated_at)
      VALUES (#{connection.quote(BASELINE_KEY)}, #{connection.quote(baseline.utc.iso8601(6))}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      ON CONFLICT (key) DO NOTHING
    SQL
    baseline
  end

  def stored_time(key)
    value = select_value("SELECT value FROM ar_internal_metadata WHERE key = #{connection.quote(key)}")
    value.present? ? Time.iso8601(value) : nil
  end

  def new_code_publishing?(cutover)
    select_value(<<~SQL.squish).present?
      SELECT 1 FROM crm_events
      WHERE created_at > #{connection.quote(cutover)} AND published_at IS NOT NULL
      LIMIT 1
    SQL
  end
end
