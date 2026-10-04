require 'rails_helper'

RSpec.describe Crm::StageVisits::ReconciliationService do
  let(:account) { create(:account) }
  let!(:deal) { create(:crm_deal, account: account) }

  it 'reports missing visits without mutating data by default' do
    report = described_class.new(account: account).perform

    expect(report[:missing]).to eq([deal.id])
    expect(deal.stage_visits).to be_empty
  end

  it 'safely creates an estimated current visit only when auto-fix is explicit' do
    occurred_at = Time.current
    report = described_class.new(account: account, auto_fix: true, occurred_at: occurred_at).perform

    visit = deal.stage_visits.active.first!
    expect(visit).to be_estimated
    expect(visit.entered_at).to be_within(0.000001).of(occurred_at)
    expect(visit.reliable_since).to be_within(0.000001).of(occurred_at)
    expect(report[:fixed]).to contain_exactly(deal_id: deal.id, visit_id: visit.id)
  end

  it 'reports a mismatched active visit without rewriting history' do
    other_stage = create(:crm_stage, account: account, pipeline: deal.pipeline)
    visit = create(:crm_stage_visit, deal: deal, stage: other_stage)

    report = described_class.new(account: account, auto_fix: true).perform

    expect(report[:mismatched]).to contain_exactly(
      deal_id: deal.id,
      visit_id: visit.id,
      visit_stage_id: other_stage.id,
      deal_stage_id: deal.stage_id
    )
    expect(visit.reload.exited_at).to be_nil
  end
end
