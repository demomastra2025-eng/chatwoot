require 'rails_helper'

RSpec.describe Crm::Deals::AutoCreateFromChannelContactService do
  let(:account) { create(:account) }
  let(:api_inbox) { create(:inbox, channel: create(:channel_api, account: account), account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: api_inbox) }

  before do
    account.enable_features!('crm_deals')
    allow(Rails.logger).to receive(:warn)
  end

  describe '#perform' do
    it 'skips the deal and logs only the error code when the default stage requires a field the new deal lacks' do
      pipeline = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      stage = create(:crm_stage, account: account, pipeline: pipeline, default: true)
      create(:crm_stage_field_requirement, stage: stage, field_key: 'description')

      expect(described_class.new(contact_inbox: contact_inbox).perform).to eq([])

      expect(account.crm_deals.where(pipeline: pipeline)).not_to exist
      expect(Rails.logger).to have_received(:warn).with(
        "Crm auto-create deal skipped: account_id=#{account.id} pipeline_id=#{pipeline.id} " \
        'error=Crm::Error code=DEAL_STAGE_REQUIRES_FIELDS'
      )
    end

    it 'still creates the deal in the next auto-create pipeline when one pipeline is skipped' do
      blocked = create(:crm_pipeline, account: account, default: true, auto_create_deal_on_channel_contact: true)
      blocked_stage = create(:crm_stage, account: account, pipeline: blocked, default: true)
      create(:crm_stage_field_requirement, stage: blocked_stage, field_key: 'description')
      open_pipeline = create(:crm_pipeline, account: account, auto_create_deal_on_channel_contact: true)
      open_stage = create(:crm_stage, account: account, pipeline: open_pipeline, default: true)

      deals = described_class.new(contact_inbox: contact_inbox).perform

      expect(deals.map(&:pipeline_id)).to eq([open_pipeline.id])
      expect(deals.first.stage_id).to eq(open_stage.id)
      expect(account.crm_deals.where(pipeline: blocked)).not_to exist
    end
  end
end
