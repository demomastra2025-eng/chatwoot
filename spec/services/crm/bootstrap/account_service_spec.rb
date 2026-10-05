require 'rails_helper'

RSpec.describe Crm::Bootstrap::AccountService do
  let(:account) { create(:account) }

  before do
    account.enable_features!('crm_deals')
  end

  describe '#perform' do
    it 'creates the system source field for deals' do
      described_class.new(account: account).perform

      source_field = account.crm_field_definitions.find_by!(entity_kind: 'deal', key: 'source')

      expect(source_field.label).to eq('Источник')
      expect(source_field.field_type).to eq('select')
      expect(source_field.active).to be(true)
      expect(source_field.system?).to be(true)
      expect(source_field.options).to include(
        hash_including('label' => 'Вручную', 'value' => 'manual'),
        hash_including('label' => 'Диалог', 'value' => 'conversation'),
        hash_including('label' => 'AI', 'value' => 'ai'),
        hash_including('label' => 'Импорт', 'value' => 'import'),
        hash_including('label' => 'Другое', 'value' => 'other')
      )
    end

    it 'creates default deal pipeline stages with won and lost colors' do
      described_class.new(account: account).perform

      pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
      stages = pipeline.stages.ordered

      expect(stages.pluck(:code)).to eq(%w[new qualified proposal won lost])
      expect(stages.find_by!(code: 'won')).to have_attributes(outcome: 'won', color: Crm::Stage::WON_COLOR)
      expect(stages.find_by!(code: 'lost')).to have_attributes(outcome: 'lost', color: Crm::Stage::LOST_COLOR)
    end

    it 'adds missing terminal stages to existing pipelines without replacing custom open stages' do
      pipeline = create(:crm_pipeline, account: account, code: 'custom_sales')
      custom_stage = create(
        :crm_stage,
        account: account,
        pipeline: pipeline,
        name: 'Lead In',
        code: 'lead_in',
        color: '#123456'
      )

      described_class.new(account: account).perform

      stages = pipeline.reload.stages.ordered

      expect(stages.pluck(:code)).to eq(%w[new lead_in won lost])
      expect(stages.find_by!(code: 'new')).not_to be_default
      expect(custom_stage.reload).to be_default
      expect(stages.find_by!(code: 'won')).to have_attributes(outcome: 'won', color: Crm::Stage::WON_COLOR)
      expect(stages.find_by!(code: 'lost')).to have_attributes(outcome: 'lost', color: Crm::Stage::LOST_COLOR)
    end

    it 'normalizes existing terminal stage colors' do
      pipeline = create(:crm_pipeline, account: account, code: 'custom_sales')
      create(:crm_stage, account: account, pipeline: pipeline, name: 'Open', code: 'open', color: '#123456')
      create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', color: '#F97316', outcome: 'won')
      create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', code: 'lost', color: '#D97706', outcome: 'lost')

      described_class.new(account: account).perform

      expect(pipeline.reload.stages.find_by!(code: 'won').color).to eq(Crm::Stage::WON_COLOR)
      expect(pipeline.stages.find_by!(code: 'lost').color).to eq(Crm::Stage::LOST_COLOR)
    end

    it 'normalizes physical system stage positions for position-only consumers' do
      pipeline = create(:crm_pipeline, account: account, code: 'custom_sales')
      open_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Open', code: 'open')
      won_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Won', code: 'won', outcome: 'won')
      lost_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Lost', code: 'lost', outcome: 'lost')

      won_stage.update!(position: 0)
      lost_stage.update!(position: 1)
      open_stage.update!(position: 9)

      described_class.new(account: account).perform

      physical_order = pipeline.reload.stages.order(:position, :id)

      expect(physical_order.pluck(:code)).to eq(%w[new open won lost])
      expect(physical_order.pluck(:position)).to eq([0, 1, 2, 3])
    end

    it 'preserves an active custom default stage during bootstrap' do
      pipeline = create(:crm_pipeline, account: account, code: 'custom_sales')
      custom_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Proposal', code: 'proposal')
      custom_stage.update!(default: true)

      described_class.new(account: account).perform

      expect(custom_stage.reload).to be_default
      expect(pipeline.reload.stages.find_by!(code: 'new')).not_to be_default
    end

    it 'preserves an intentionally disabled technical stage and the custom default' do
      pipeline = create(:crm_pipeline, account: account, code: 'custom_sales')
      technical_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Unsorted', code: 'new')
      custom_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Proposal', code: 'proposal')
      custom_stage.update!(default: true)
      # Seeds legacy data that current model validation correctly rejects, so bootstrap repair is verified.
      technical_stage.update_columns(active: false, default: true) # rubocop:disable Rails/SkipsModelValidations

      described_class.new(account: account).perform

      expect(custom_stage.reload).to be_default
      expect(technical_stage.reload).to have_attributes(active: false, default: false)
    end

    it 'moves the default to an active open stage when the technical stage is disabled' do
      pipeline = create(:crm_pipeline, account: account, code: 'custom_sales')
      technical_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Unsorted', code: 'new')
      custom_stage = create(:crm_stage, account: account, pipeline: pipeline, name: 'Proposal', code: 'proposal')
      # Seeds legacy data that current model validation correctly rejects, so bootstrap repair is verified.
      technical_stage.update_columns(active: false, default: true) # rubocop:disable Rails/SkipsModelValidations

      described_class.new(account: account).perform

      expect(technical_stage.reload).to have_attributes(active: false, default: false)
      expect(custom_stage.reload).to be_default
    end

    it 'ensures the system source field even when deal pipelines already exist' do
      create(:crm_pipeline, account: account)

      described_class.new(account: account).perform

      source_field = account.crm_field_definitions.find_by!(entity_kind: 'deal', key: 'source')
      expect(source_field).to be_system
    end

    it 'keeps existing source values valid when converting a legacy source field' do
      create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'source', label: 'Lead source', field_type: 'text')
      create(:crm_deal, account: account, custom_attributes: { 'source' => 'partner_referral' })
      create(:crm_deal, account: account, custom_attributes: { 'source' => 'partner_referral' })
      create(:crm_deal, account: account, custom_attributes: { 'source' => '' })

      described_class.new(account: account).perform

      source_field = account.crm_field_definitions.find_by!(entity_kind: 'deal', key: 'source')
      expect(source_field.label).to eq('Lead source')
      expect(source_field.field_type).to eq('select')
      expect(source_field.options).to include(hash_including('label' => 'partner_referral', 'value' => 'partner_referral'))
      expect(source_field.options.count { |option| option['value'] == 'partner_referral' }).to eq(1)
    end

    it 'creates a note-required other outcome for every default task type' do
      account.enable_features!('crm_tasks')
      described_class.new(account: account).perform

      account.crm_task_types.find_each do |task_type|
        outcome = task_type.outcomes.find_by(code: 'other')

        expect(outcome).to be_present
        expect(outcome).to be_active
        expect(outcome).to be_requires_note
      end
    end
  end

  describe '#perform_if_needed' do
    let(:service) { described_class.new(account: account) }

    before { account.enable_features!('crm_tasks') }

    it 'provisions the defaults on the first call' do
      service.perform_if_needed

      expect(account.crm_pipelines.pluck(:code)).to eq(['sales_pipeline'])
      expect(account.crm_task_types.pluck(:code)).to include('task', 'call')
      expect(account.crm_task_statuses.pluck(:code)).to include('todo', 'done')
    end

    it 'does not touch the database again while the marker is set' do
      service.perform_if_needed
      allow(ApplicationRecord).to receive(:transaction).and_call_original

      queries = sql_queries_during { described_class.new(account: account).perform_if_needed }

      expect(queries).to be_empty
      expect(ApplicationRecord).not_to have_received(:transaction)
    end

    it 'bootstraps again once the marker is gone' do
      service.perform_if_needed
      account.crm_pipelines.destroy_all
      Redis::Alfred.delete(service.send(:bootstrapped_marker_key))

      service.perform_if_needed

      expect(account.crm_pipelines.pluck(:code)).to eq(['sales_pipeline'])
    end

    it 'bootstraps again when the set of enabled CRM features changes' do
      account.disable_features!('crm_tasks')
      service.perform_if_needed
      expect(account.crm_task_types).to be_empty

      account.enable_features!('crm_tasks')
      described_class.new(account: account).perform_if_needed

      expect(account.crm_task_types.pluck(:code)).to include('task')
    end

    it 'does not share the marker between accounts' do
      other_account = create(:account)
      other_account.enable_features!('crm_deals', 'crm_tasks')
      service.perform_if_needed

      described_class.new(account: other_account).perform_if_needed

      expect(other_account.crm_pipelines.pluck(:code)).to eq(['sales_pipeline'])
    end

    it 'falls back to the full bootstrap when Redis is unavailable' do
      allow(Redis::Alfred).to receive(:exists?).and_raise(Redis::CannotConnectError)
      allow(Redis::Alfred).to receive(:set).and_raise(Redis::CannotConnectError)

      expect { service.perform_if_needed }.not_to raise_error
      expect(account.crm_pipelines.pluck(:code)).to eq(['sales_pipeline'])
    end
  end
end
