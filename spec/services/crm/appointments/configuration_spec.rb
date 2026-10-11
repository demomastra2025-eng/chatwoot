require 'rails_helper'

RSpec.describe Crm::Appointments::Configuration do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true) }

  it 'defaults appointment creation OFF without consulting incoming-channel creation' do
    expect(described_class.for(pipeline)).to include('auto_create_deals' => false, 'auto_create_from_calendar' => false)
  end

  it 'preserves explicit legacy source opt-ins only while the master setting is absent' do
    expect(described_class.normalize({ 'auto_create_from_calendar' => true })).to include('auto_create_deals' => true)
    expect(described_class.normalize({ 'auto_create_from_medelement' => true })).to include('auto_create_deals' => true)
    expect(described_class.normalize({ 'enabled' => true })).to include('auto_create_deals' => false)
    expect(described_class.normalize({ 'auto_create_deals' => false, 'auto_create_from_calendar' => true }))
      .to include('auto_create_deals' => false, 'auto_create_from_calendar' => true)
  end

  it 'does not claim a source or disable another target when saving retained source flags with master OFF' do
    target = create(:crm_pipeline, account: account, appointment_automation: {
                      auto_create_from_calendar: true, auto_create_from_medelement: true
                    })
    original_config = target.appointment_automation.deep_dup
    pipeline.update!(appointment_automation: {
                       auto_create_deals: false, auto_create_from_calendar: true, auto_create_from_medelement: true
                     })

    expect(target.reload.appointment_automation).to eq(original_config)
    expect(pipeline.appointment_automation).not_to have_key('auto_create_from_calendar_enabled_at')
    expect(pipeline.appointment_automation).not_to have_key('auto_create_from_medelement_enabled_at')
  end

  %w[auto_create_from_calendar auto_create_from_medelement].each do |source_key|
    it "preserves OFF source flags and history when another pipeline enables #{source_key}" do
      config = { 'auto_create_deals' => false, source_key => true, "#{source_key}_enabled_at" => '2026-10-01T00:00:00Z' }
      pipeline.update!(appointment_automation: config)
      original_config = pipeline.appointment_automation.deep_dup

      target = create(:crm_pipeline, account: account, appointment_automation: { source_key => true })

      expect(described_class.for(target)).to include('auto_create_deals' => true, source_key => true)
      expect(pipeline.reload.appointment_automation).to eq(original_config)
      expect(target.appointment_automation["#{source_key}_enabled_at"]).to be_present
    end
  end

  it 'uses a fresh prospective boundary when master creation is reenabled with a retained source flag' do
    travel_to(Time.utc(2026, 10, 10, 7)) do
      pipeline.update!(appointment_automation: { auto_create_from_medelement: true })
      previous_boundary = pipeline.appointment_automation['auto_create_from_medelement_enabled_at']
      pipeline.update!(appointment_automation: pipeline.appointment_automation.merge('auto_create_deals' => false))

      travel 1.day
      pipeline.update!(appointment_automation: pipeline.appointment_automation.merge('auto_create_deals' => true))
      expect(Time.iso8601(pipeline.appointment_automation['auto_create_from_medelement_enabled_at'])).to eq(Time.current)
      expect(pipeline.appointment_automation['auto_create_from_medelement_enabled_at']).not_to eq(previous_boundary)
    end
  end

  it 'can disable creation without repairing an unchanged legacy invalid stage rule first' do
    pipeline.update_column(:appointment_automation, {
                             'auto_create_deals' => true,
                             'rules' => [{ 'stage_id' => 0, 'scope' => 'any', 'conditions' => ['scheduled'] }]
                           })
    expect { pipeline.update!(appointment_automation: pipeline.appointment_automation.merge('auto_create_deals' => false)) }.not_to raise_error
    expect(described_class.for(pipeline)['auto_create_deals']).to be false
  end

  it 'removes ordinary reasons from normalized rules while preserving loss reasons' do
    rule = { 'stage_id' => 1, 'transition_reason' => 'Old reason', 'closing_reasons' => ['Price'] }
    config = described_class.normalize({ 'rules' => [rule] })

    expect(config['rules']).to eq([{ 'stage_id' => 1, 'closing_reasons' => ['Price'] }])
    expect(rule['transition_reason']).to eq('Old reason')
  end

  it 'keeps closing reasons only on lost appointment rules' do
    won = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won')
    lost = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'lost', closing_reason_options: ['Price'], closing_reason_required: true)
    rules = [
      { stage_id: won.id, scope: 'any', conditions: ['attended'], closing_reasons: ['Won reason'] },
      { stage_id: lost.id, scope: 'any', conditions: ['cancelled'], closing_reasons: ['Price'] }
    ]
    pipeline.update!(appointment_automation: { enabled: true, rules: rules })

    expect(pipeline.appointment_automation['rules'].first).not_to have_key('closing_reasons')
    expect(pipeline.appointment_automation['rules'].last['closing_reasons']).to eq(['Price'])
    expect(described_class.validate(pipeline)).to be_empty
  end
end
