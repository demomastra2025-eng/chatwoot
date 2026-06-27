# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::PayloadBuilder do
  describe '.pipeline' do
    let(:account) { create(:account) }
    let(:pipeline) { create(:crm_pipeline, account: account) }
    let(:stage) { create(:crm_stage, account: account, pipeline: pipeline) }
    let(:other_stage) { create(:crm_stage, account: account, pipeline: pipeline) }

    before do
      account.enable_features!('communication_threads')
    end

    it 'keeps total deal counts separate from deal counts with a dialog context' do
      direct_conversation = create(:conversation, account: account)
      thread_conversation = create(:conversation, account: account)
      contact_conversation = create(:conversation, account: account)
      communication_thread = thread_conversation.refresh_communication_thread!

      create(:crm_deal, account: account, pipeline: pipeline, stage: stage,
                        originating_conversation: direct_conversation)
      create(:crm_deal, account: account, pipeline: pipeline, stage: stage,
                        originating_communication_thread: communication_thread)
      create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
      create(:crm_deal, account: account, pipeline: pipeline, stage: stage,
                        originating_conversation: direct_conversation, archived_at: Time.current)

      contact_deal = create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage)
      create(:crm_deal_contact, account: account, deal: contact_deal, contact: contact_conversation.contact)

      payload = described_class.pipeline(pipeline)
      stages_by_id = payload.fetch(:stages).index_by { |item| item[:id] }

      expect(payload).to include(
        deal_count: 4,
        dialog_deal_count: 3
      )
      expect(stages_by_id.fetch(stage.id)).to include(
        deal_count: 3,
        dialog_deal_count: 2
      )
      expect(stages_by_id.fetch(other_stage.id)).to include(
        deal_count: 1,
        dialog_deal_count: 1
      )
    end
  end
end
