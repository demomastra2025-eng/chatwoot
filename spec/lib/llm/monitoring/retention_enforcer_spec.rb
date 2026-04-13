# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::Monitoring::RetentionEnforcer do
  describe '#call' do
    let(:account) { create(:account, captain_observability: { 'retention_days' => 30 }) }
    let(:user) { create(:user, account: account, role: :administrator) }
    let!(:old_event) { create(:llm_event, account: account, created_at: 45.days.ago) }
    let!(:recent_event) { create(:llm_event, account: account, created_at: 10.days.ago) }
    let!(:global_old_event) { create(:llm_event, account: nil, created_at: 120.days.ago) }
    let!(:old_annotation) { create(:llm_event_annotation, account: account, user: user, llm_event: old_event) }
    let!(:recent_annotation) { create(:llm_event_annotation, account: account, user: user, llm_event: recent_event) }

    it 'removes stale llm events and dependent annotations according to retention windows' do
      summary = described_class.new(
        account_scope: Account.where(id: account.id),
        event_scope: LlmEvent.where(id: [old_event.id, recent_event.id, global_old_event.id]),
        now: Time.current
      ).call

      expect(summary).to include(
        processed_accounts: be >= 1,
        deleted_events: 2,
        deleted_annotations: 1
      )
      expect(LlmEvent.exists?(old_event.id)).to be(false)
      expect(LlmEvent.exists?(global_old_event.id)).to be(false)
      expect(LlmEvent.exists?(recent_event.id)).to be(true)
      expect(LlmEventAnnotation.exists?(old_annotation.id)).to be(false)
      expect(LlmEventAnnotation.exists?(recent_annotation.id)).to be(true)
    end
  end
end
