require 'rails_helper'

RSpec.describe Crm::Stages::BatchUpdateService do
  let(:account) { create(:account) }
  let(:pipeline) { account.crm_pipelines.find_by!(code: 'sales_pipeline') }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  def open_stage_draft_rows(pipeline, default_stage_id:)
    pipeline.stages.where(outcome: 'open')
            .where.not(code: Crm::Stage::TECHNICAL_STAGE_CODES)
            .order(:position, :id).map do |stage|
      {
        id: stage.id,
        name: stage.name,
        color: stage.color,
        active: stage.active,
        default: stage.id == default_stage_id,
        transition_reason_options: stage.transition_reason_options,
        transition_reason_required: stage.transition_reason_required
      }
    end
  end

  def terminal_stage_draft_rows(pipeline)
    pipeline.stages.where(outcome: Crm::Stage::TERMINAL_OUTCOMES).map do |stage|
      {
        id: stage.id,
        name: stage.name,
        closing_reason_options: stage.closing_reason_options,
        closing_reason_required: stage.closing_reason_required
      }
    end
  end

  def saved_open_stage_ids(pipeline)
    pipeline.stages.where(outcome: 'open')
            .where.not(code: Crm::Stage::TECHNICAL_STAGE_CODES)
            .order(:position, :id).pluck(:id)
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

    stages = open_stage_draft_rows(pipeline, default_stage_id: reason_stage.id).reverse
    terminal_stages = terminal_stage_draft_rows(pipeline)
    service = described_class.new(
      pipeline: pipeline,
      attributes: {
        deleted_stage_ids: [],
        stages: stages,
        terminal_stages: terminal_stages
      }
    )
    expect(pipeline).to receive(:with_lock).and_call_original

    service.perform

    expect(saved_open_stage_ids(pipeline)).to eq(stages.map { |stage| stage[:id] })
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

  it 'rejects an incomplete movable order before the terminal draft without changing stages' do
    original_stages = pipeline.stages.order(:id).pluck(
      :id, :name, :position, :active, :default, :outcome, :transition_reason_options,
      :transition_reason_required, :closing_reason_options, :closing_reason_required
    )
    open_stages = pipeline.stages.where(outcome: 'open').map do |open_stage|
      { id: open_stage.id, name: open_stage.name, color: open_stage.color, active: open_stage.active }
    end

    expect do
      described_class.new(
        pipeline: pipeline,
        attributes: {
          stages: open_stages,
          terminal_stages: [{ id: pipeline.stages.find_by!(code: 'won').id, name: 'Changed' }]
        }
      ).perform
    end.to raise_error(Crm::Error) { |error|
      expect(error.code).to eq('INVALID_STAGE_ORDER')
      expect(error.message).to eq('Stage order must contain every movable stage in this pipeline exactly once.')
    }

    persisted_stages = pipeline.stages.order(:id).pluck(
      :id, :name, :position, :active, :default, :outcome, :transition_reason_options,
      :transition_reason_required, :closing_reason_options, :closing_reason_required
    )
    expect(persisted_stages).to eq(original_stages)
  end
end
