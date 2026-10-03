require 'rails_helper'

RSpec.describe Crm::Stages::BatchUpdateService do
  let(:account) { create(:account) }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'applies a complete ordered draft under one pipeline lock and preserves existing configuration' do
    reason_stage = pipeline.stages.find_by!(code: 'proposal')
    reason_stage.update!(
      transition_reason_options: ['Budget confirmed'],
      transition_reason_required: true
    )
    default_stage = pipeline.stages.find_by!(default: true)
    terminal_stage = pipeline.stages.find_by!(code: 'lost')
    terminal_stage.update!(closing_reason_options: ['Price'], closing_reason_required: true)

    stages = ::Crm::Stage.where(pipeline_id: pipeline.id, outcome: 'open').order(:position, :id).map do |stage|
      {
        id: stage.id,
        name: stage.name,
        color: stage.color,
        active: stage.active,
        default: stage.id == reason_stage.id,
        transition_reason_options: stage.transition_reason_options,
        transition_reason_required: stage.transition_reason_required,
      }
    end.reverse
    terminal_stages = ::Crm::Stage.where(pipeline_id: pipeline.id, outcome: ::Crm::Stage::TERMINAL_OUTCOMES).map do |stage|
      {
        id: stage.id,
        name: stage.name,
        closing_reason_options: stage.closing_reason_options,
        closing_reason_required: stage.closing_reason_required,
      }
    end
    service = described_class.new(
      pipeline: pipeline,
      attributes: {
        deleted_stage_ids: [],
        stages: stages,
        terminal_stages: terminal_stages,
      }
    )
    expect(pipeline).to receive(:with_lock).and_call_original

    service.perform

    expect(::Crm::Stage.where(pipeline_id: pipeline.id, outcome: 'open').order(:position, :id).pluck(:id)).to eq(
      stages.map { |stage| stage[:id] }
    )
    expect(reason_stage.reload).to have_attributes(
      default: true,
      transition_reason_options: ['Budget confirmed'],
      transition_reason_required: true
    )
    expect(default_stage.reload).not_to be_default
    expect(terminal_stage.reload).to have_attributes(
      closing_reason_options: ['Price'],
      closing_reason_required: true
    )
  end
end
