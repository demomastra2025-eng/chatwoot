require 'rails_helper'
require Rails.root.join('db/migrate/20261011090000_normalize_crm_appointment_creation_and_stage_reasons')

RSpec.describe NormalizeCrmAppointmentCreationAndStageReasons do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true) }
  let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
  let(:lost) do
    create(:crm_stage, account: account, pipeline: pipeline, outcome: 'lost', closing_reason_options: ['Price'], closing_reason_required: true)
  end

  def legacy_config(record, config)
    # Write the previous release's representation without the new normalizer.
    record.update_column(:appointment_automation, config)
  end

  it 'cleans only ordinary reasons and preserves event envelopes, loss reasons and unrelated metadata on repeated runs', :aggregate_failures do
    stage.update_columns(transition_reason_options: ['Old reason'], transition_reason_required: true)
    legacy_config(pipeline, {
                    'auto_create_from_calendar' => true, 'auto_create_from_calendar_enabled_at' => '2026-10-01T00:00:00Z',
                    'rules' => [{ 'stage_id' => lost.id, 'scope' => 'any', 'conditions' => ['cancelled'],
                                 'closing_reasons' => ['Price'], 'transition_reason' => 'Old reason', 'name' => 'Keep rule' }]
                  })
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost, closing_reasons: ['Price'], closed_at: Time.current)
    event = create(:crm_event, account: account, eventable: deal, event_type: 'deal_stage_changed',
                               meta: { transition_reason: 'Old reason', closing_reasons: ['Price'], from_stage_id: stage.id,
                                       to_stage_id: lost.id, comment: 'Keep this note', command_fingerprint: 'keep-fingerprint' })
    original = event.attributes
    original_lost = lost.attributes

    2.times { described_class.new.up }

    expect(stage.reload).to have_attributes(transition_reason_options: [], transition_reason_required: false)
    expect(pipeline.reload.appointment_automation).to include(
      'auto_create_deals' => true, 'auto_create_from_calendar' => true,
      'auto_create_from_calendar_enabled_at' => '2026-10-01T00:00:00Z'
    )
    rule = pipeline.appointment_automation['rules'].first
    expect(rule).not_to have_key('transition_reason')
    expect(rule).to include('closing_reasons' => ['Price'], 'name' => 'Keep rule', 'stage_id' => lost.id)
    expect(event.reload.attributes).to eq(original.merge('meta' => original['meta'].except('transition_reason')))
    expect(lost.reload.attributes).to eq(original_lost)
    expect(deal.reload.closing_reasons).to eq(['Price'])
  end

  it 'defaults channel-only pipelines OFF, derives only explicit legacy source opt-ins, and preserves an explicit master OFF' do
    legacy_config(pipeline, {})
    provider_target = create(:crm_pipeline, account: account)
    legacy_config(provider_target, 'auto_create_from_medelement' => true)
    disabled = create(:crm_pipeline, account: account)
    legacy_config(disabled, 'auto_create_deals' => false, 'auto_create_from_calendar' => true)
    stages_only = create(:crm_pipeline, account: account)
    legacy_config(stages_only, 'enabled' => true)

    2.times { described_class.new.up }

    expect(pipeline.reload).to have_attributes(auto_create_deal_on_channel_contact: true)
    expect(pipeline.appointment_automation['auto_create_deals']).to be false
    expect(provider_target.reload.appointment_automation['auto_create_deals']).to be true
    expect(disabled.reload.appointment_automation).to include('auto_create_deals' => false, 'auto_create_from_calendar' => true)
    expect(stages_only.reload.appointment_automation).to include('auto_create_deals' => false, 'enabled' => true)
  end

  it 'uses no model callbacks or automation/provider jobs for cleanup' do
    legacy_config(pipeline, 'auto_create_from_calendar' => true)
    expect(Crm::Appointments::RefreshPipelineJob).not_to receive(:perform_later)
    expect(Crm::Appointments::EvaluateDealJob).not_to receive(:perform_later)

    described_class.new.up
  end

  it 'clears known won configuration without deleting historical closing-reason arrays from deals or events' do
    won = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won')
    won.update_columns(closing_reason_options: ['Legacy won option'], closing_reason_required: true)
    legacy_config(pipeline, 'rules' => [{ 'stage_id' => won.id, 'closing_reasons' => ['Legacy won option'] }])
    legacy_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: won, closed_at: Time.current)
    legacy_deal.update_column(:closing_reasons, ['Previous loss history'])
    event = create(:crm_event, account: account, eventable: legacy_deal,
                               meta: { closing_reasons: ['Previous loss history'], from_closing_reasons: ['Price'] })
    original_meta = event.meta

    2.times { described_class.new.up }

    expect(won.reload).to have_attributes(closing_reason_options: [], closing_reason_required: false)
    expect(pipeline.reload.appointment_automation['rules'].first).not_to have_key('closing_reasons')
    expect(legacy_deal.reload.closing_reasons).to eq(['Previous loss history'])
    expect(event.reload.meta).to eq(original_meta)
    expect(Crm::PayloadBuilder.deal(legacy_deal)[:closing_reasons]).to eq([])
    legacy_deal.update!(title: 'Unrelated edit preserves legacy loss data')
    expect(legacy_deal.reload.closing_reasons).to eq(['Previous loss history'])
  end

  it 'cannot reconstruct intentionally removed reasons in a rollback' do
    expect { described_class.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it 'resumes an interrupted cleanup across small batches without changing loss metadata or event envelopes' do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    deal = create(:crm_deal, account: account, pipeline: pipeline, stage: lost, closing_reasons: ['Price'], closed_at: Time.current)
    events = create_list(:crm_event, 5, account: account, eventable: deal, event_type: 'deal_stage_changed',
                                      meta: { transition_reason: 'Obsolete', closing_reasons: ['Price'], comment: 'Retained note' })
    original = events.map(&:attributes)
    migration = described_class.new
    allow(migration).to receive(:clear_event_transition_reasons).and_wrap_original do |method, low, high|
      method.call(low, high)
      cleaned = Crm::Event.where(id: events.map(&:id)).where("NOT (meta ? 'transition_reason')").count
      raise 'Synthetic cleanup interruption' if cleaned.positive? && cleaned < events.size
    end

    expect { ActiveRecord::Migration.suppress_messages { migration.up } }.to raise_error('Synthetic cleanup interruption')
    expect(Crm::Event.where(id: events.map(&:id)).where("meta ? 'transition_reason'").count).to be_between(1, 4)

    2.times { ActiveRecord::Migration.suppress_messages { described_class.new.up } }

    expected = original.map { |attributes| attributes.merge('meta' => attributes['meta'].except('transition_reason')) }
    expect(events.map { |event| event.reload.attributes }).to eq(expected)
    expect(deal.reload.closing_reasons).to eq(['Price'])
  end
end
