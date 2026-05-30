require 'rails_helper'

RSpec.describe Crm::Deals::UpsertService do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account, default: true) }

  it 'creates deals in the configured default stage for the selected pipeline' do
    first_open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 1,
      color: '#123456',
      default: true
    )
    default_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 5,
      color: '#654321',
      default: true
    )

    deal = described_class.new(
      account: account,
      params: { title: 'Default-stage deal', pipeline_id: pipeline.id }
    ).perform

    expect(deal.stage).to eq(default_stage)
    expect(first_open_stage.reload).not_to be_default
  end

  it 'falls back to the first active open stage when no explicit default exists' do
    won_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 1,
      outcome: 'won',
      color: '#123456'
    )
    first_open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 2,
      color: '#654321'
    )
    later_open_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      position: 3,
      color: '#111111'
    )
    pipeline.stages.each { |stage| stage.update!(default: false) }

    deal = described_class.new(
      account: account,
      params: { title: 'Fallback-stage deal', pipeline_id: pipeline.id }
    ).perform

    expect(deal.stage).to eq(first_open_stage)
    expect(deal.stage).not_to eq(won_stage)
    expect(deal.stage).not_to eq(later_open_stage)
  end
end
