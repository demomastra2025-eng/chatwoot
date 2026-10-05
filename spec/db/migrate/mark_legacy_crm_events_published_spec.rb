require 'rails_helper'
require Rails.root.join('db/migrate/20261004193200_mark_legacy_crm_events_published')

RSpec.describe MarkLegacyCrmEventsPublished, :crm_lifecycle_ddl do
  let(:account) { create(:account) }
  let(:cutover_key) { 'crm_events_envelope_cutover' }
  let(:baseline_key) { described_class::BASELINE_KEY }

  def insert_event(created_at:, published: false)
    id = db.select_value(<<~SQL.squish)
      INSERT INTO crm_events (account_id, eventable_type, eventable_id, event_type, meta, created_at)
      VALUES (#{account.id}, 'Crm::Deal', 1, 'deal_updated', '{}', #{db.quote(created_at)}) RETURNING id
    SQL
    db.execute("UPDATE crm_events SET published_at = created_at WHERE id = #{id}") if published
    id
  end

  def published?(id)
    !db.select_value("SELECT published_at FROM crm_events WHERE id = #{id}").nil?
  end

  def record_cutover(time)
    set_metadata(cutover_key, time.utc.iso8601(6))
  end

  it 'marks the events the previous release wrote while the migrations ran, and nothing newer' do
    record_cutover(10.minutes.ago)
    during_migrations = insert_event(created_at: 5.minutes.ago)
    after_baseline = insert_event(created_at: 1.hour.from_now)

    run_migration(:publication)

    expect(published?(during_migrations)).to be(true)
    expect(published?(after_baseline)).to be(false)
    expect(Time.iso8601(metadata(baseline_key))).to be_within(1.minute).of(Time.current)
  end

  it 'does not move the boundary on a re-run, so work queued by the new release is never marked' do
    record_cutover(10.minutes.ago)
    run_migration(:publication)
    baseline = metadata(baseline_key)
    queued_by_new_release = insert_event(created_at: 1.hour.from_now)
    still_pending = insert_event(created_at: 1.minute.from_now)

    run_migration(:publication, times: 2)

    expect(metadata(baseline_key)).to eq(baseline)
    expect([published?(queued_by_new_release), published?(still_pending)]).to eq([false, false])
  end

  it 'keeps the boundary at the cutover when the new release is already publishing events' do
    record_cutover(10.minutes.ago)
    insert_event(created_at: 5.minutes.ago, published: true)
    live_event = insert_event(created_at: 2.minutes.ago)

    run_migration(:publication)

    expect(published?(live_event)).to be(false)
    expect(Time.iso8601(metadata(baseline_key))).to eq(Time.iso8601(metadata(cutover_key)))
  end

  it 'marks nothing when the columns predate the migration chain (no cutover or epoch)' do
    db.execute("DELETE FROM ar_internal_metadata WHERE key IN ('#{cutover_key}', '#{baseline_key}')")
    pending_event = insert_event(created_at: 1.day.ago)

    run_migration(:publication)

    expect(published?(pending_event)).to be(false)

    record_cutover(Time.at(0).utc)
    db.execute("DELETE FROM ar_internal_metadata WHERE key = '#{baseline_key}'")

    run_migration(:publication)

    expect(published?(pending_event)).to be(false)
  end

  it 'works through the table in batches' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    record_cutover(10.minutes.ago)
    ids = Array.new(5) { |index| insert_event(created_at: (index + 1).minutes.ago) }

    run_migration(:publication)

    expect(ids.map { |id| published?(id) }).to all(be(true))
  end

  it 'is irreversible' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
