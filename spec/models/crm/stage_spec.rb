require 'rails_helper'

RSpec.describe Crm::Stage do
  let(:account) { create(:account) }
  let(:pipeline) { create(:crm_pipeline, account: account) }

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
end
