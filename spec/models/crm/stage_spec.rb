require 'rails_helper'

RSpec.describe Crm::Stage do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }

  it 'uses 20 unique non-white standard colors' do
    expect(described_class::STANDARD_COLORS.length).to eq(20)
    expect(described_class::STANDARD_COLORS.uniq.length).to eq(20)
    expect(described_class::STANDARD_COLORS).not_to include('#F0F0F3', '#E8E8EC', '#FFFFFF')
  end

  it 'assigns the next available spectrum color on create' do
    create(:crm_stage, account: account, pipeline: pipeline, color: described_class::DEFAULT_COLOR)

    stage = create(:crm_stage, account: account, pipeline: pipeline, color: nil)

    expect(stage.color).to eq('#DC2626')
  end

  it 'places new open stages before terminal won and lost stages when position is omitted' do
    create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 1)
    won_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'won', outcome: 'won', position: 2)
    lost_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'lost', outcome: 'lost', position: 3)

    follow_up = create(:crm_stage, account: account, pipeline: pipeline, code: 'follow_up', position: nil)

    expect(follow_up.position).to eq(2)
    expect(won_stage.reload.position).to eq(3)
    expect(lost_stage.reload.position).to eq(4)
    expect(pipeline.stages.reload.ordered.pluck(:code)).to eq(%w[new follow_up won lost])
  end

  it 'orders terminal stages last even when their numeric position is stale' do
    won_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'won', outcome: 'won', position: 1)
    lost_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'lost', outcome: 'lost', position: 2)
    open_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'open', position: 3)

    expect(pipeline.stages.reload.ordered).to eq([open_stage, won_stage, lost_stage])
  end

  it 'keeps technical, movable, won and lost stages in their system order' do
    won_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'won', outcome: 'won', position: 1)
    lost_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'lost', outcome: 'lost', position: 2)
    open_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'qualified', position: 3)
    technical_stage = create(:crm_stage, account: account, pipeline: pipeline, code: 'new', position: 99)

    expect(pipeline.stages.reload.ordered).to eq([technical_stage, open_stage, won_stage, lost_stage])
    expect(technical_stage).to be_system_stage
    expect(technical_stage).to be_position_locked
  end

  it 'marks the first active open stage in a pipeline as default' do
    stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456'
    )

    expect(stage.reload).to be_default
  end

  it 'keeps later active open stages non-default when a pipeline already has a default' do
    default_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456'
    )

    next_stage = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#654321'
    )

    expect(default_stage.reload).to be_default
    expect(next_stage.reload).not_to be_default
  end

  it 'moves the default flag to the newly selected active open stage' do
    old_default = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456',
      default: true
    )
    new_default = create(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#654321',
      default: true
    )

    expect(new_default.reload).to be_default
    expect(old_default.reload).not_to be_default
  end

  it 'rejects inactive default stages' do
    stage = build(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456',
      active: false,
      default: true
    )

    expect(stage).to be_invalid
    expect(stage.errors[:default]).to include('must be an active open stage')
  end

  it 'rejects non-open default stages' do
    stage = build(
      :crm_stage,
      account: account,
      pipeline: pipeline,
      color: '#123456',
      outcome: 'won',
      default: true
    )

    expect(stage).to be_invalid
    expect(stage.errors[:default]).to include('must be an active open stage')
  end

  describe 'account cache invalidation' do
    let(:stage) { create(:crm_stage, account: account, pipeline: pipeline, color: '#654321') }

    before { create(:crm_stage, account: account, pipeline: pipeline, color: '#123456') }

    it 'updates the CRM stage cache key after stage create' do
      expect(account).to receive(:update_cache_key).with('crm/stage')
      create(:crm_stage, account: account, pipeline: pipeline, color: '#ABCDEF')
    end

    it 'updates the CRM stage cache key after stage archive' do
      expect(stage.account).to receive(:update_cache_key).with('crm/stage')
      stage.update!(active: false)
    end

    it 'updates the CRM stage cache key after stage update' do
      expect(stage.account).to receive(:update_cache_key).with('crm/stage')
      stage.update!(name: 'Follow-up')
    end
  end
end
