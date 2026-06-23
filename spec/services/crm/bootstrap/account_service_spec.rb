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
      create(:crm_stage, account: account, pipeline: pipeline, name: 'Lead In', code: 'lead_in', color: '#123456')

      described_class.new(account: account).perform

      stages = pipeline.reload.stages.ordered

      expect(stages.pluck(:code)).to eq(%w[lead_in won lost])
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

    it 'ensures the system source field even when deal pipelines already exist' do
      create(:crm_pipeline, account: account)

      described_class.new(account: account).perform

      source_field = account.crm_field_definitions.find_by!(entity_kind: 'deal', key: 'source')
      expect(source_field).to be_system
    end

    it 'keeps existing source values valid when converting a legacy source field' do
      create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'source', label: 'Lead source', field_type: 'text')
      create(:crm_deal, account: account, custom_attributes: { 'source' => 'partner_referral' })

      described_class.new(account: account).perform

      source_field = account.crm_field_definitions.find_by!(entity_kind: 'deal', key: 'source')
      expect(source_field.label).to eq('Lead source')
      expect(source_field.field_type).to eq('select')
      expect(source_field.options).to include(hash_including('label' => 'partner_referral', 'value' => 'partner_referral'))
    end
  end
end
