require 'rails_helper'

RSpec.describe Crm::Event do
  describe 'correlation identity' do
    it 'assigns a correlation id before validation' do
      event = described_class.new(correlation_id: nil)

      event.validate

      expect(event.correlation_id).to be_present
    end

    it 'preserves an explicitly supplied correlation id' do
      correlation_id = SecureRandom.uuid
      event = described_class.new(correlation_id: correlation_id)

      event.validate

      expect(event.correlation_id).to eq(correlation_id)
    end

    it 'persists events written through the legacy writer' do
      account = create(:account)
      pipeline = create(:crm_pipeline, account: account)
      stage = create(:crm_stage, account: account, pipeline: pipeline)
      deal = create(:crm_deal, account: account, pipeline: pipeline, stage: stage)
      actor = create(:user, account: account, role: :administrator)
      allow(Rails.configuration.dispatcher).to receive(:dispatch)

      event = Crm::Events::Writer.record!(
        account: account,
        eventable: deal,
        actor: actor,
        event_type: 'deal_updated'
      )

      expect(event.reload.correlation_id).to be_present
    end
  end
end
