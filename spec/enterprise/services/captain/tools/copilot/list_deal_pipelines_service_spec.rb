require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListDealPipelinesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  before do
    account.enable_features!('crm_deals')
  end

  it 'returns active account pipelines with ordered stages without deal aggregates' do
    default_pipeline = create(:crm_pipeline, account: account, name: 'Andalusiya', code: 'andalusiya', position: 2, default: true)
    secondary_pipeline = create(:crm_pipeline, account: account, name: 'Andalusiya2', code: 'andalusiya2', position: 1)
    archived_pipeline = create(:crm_pipeline, account: account, name: 'Archived', code: 'archived', active: false, position: 3)

    stage_a = create(:crm_stage, account: account, pipeline: secondary_pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')
    stage_b = create(:crm_stage, account: account, pipeline: secondary_pipeline, name: 'В работе', code: 'work', position: 2, color: '#222222')
    create(:crm_stage, account: account, pipeline: default_pipeline, name: 'Новый', code: 'new', position: 1, color: '#333333')
    inactive_stage = create(:crm_stage, account: account, pipeline: secondary_pipeline, name: 'Inactive', code: 'inactive', active: false,
                                        position: 3, color: '#444444')
    create(:crm_stage, account: account, pipeline: archived_pipeline, name: 'Hidden', code: 'hidden', position: 1, color: '#555555')
    create(:crm_deal, account: account, pipeline: secondary_pipeline, stage: stage_b)

    payload = JSON.parse(service.execute)

    expect(payload['action']).to eq('list_deal_pipelines')
    expect(payload['returned_count']).to eq(2)
    expect(payload['pipelines'].map { |pipeline| pipeline['code'] }).to eq(%w[andalusiya2 andalusiya])

    secondary_payload = payload['pipelines'].first
    expect(secondary_payload).not_to have_key('deal_count')
    expect(secondary_payload).to include(
      'id' => secondary_pipeline.id,
      'name' => 'Andalusiya2',
      'code' => 'andalusiya2',
      'position' => 1,
      'default' => false
    )
    expect(secondary_payload['stages'].map { |stage| stage['id'] }).to eq([stage_a.id, stage_b.id])
    expect(secondary_payload['stages']).not_to include(include('id' => inactive_stage.id))
    expect(secondary_payload['stages'].first).to include(
      'name' => 'Новый',
      'code' => 'new',
      'position' => 1,
      'outcome' => 'open',
      'default' => true,
      'active' => true
    )
    expect(secondary_payload['stages'].second).to include(
      'id' => stage_b.id,
      'default' => false
    )
  end
end
