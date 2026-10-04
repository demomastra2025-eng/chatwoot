require 'rails_helper'

RSpec.describe Crm::StageVisits::ReconcileJob do
  let(:account) { create(:account) }
  let!(:deal) { create(:crm_deal, account: account) }

  it 'runs reconciliation in report-only mode' do
    report = described_class.perform_now(account_id: account.id)

    expect(report[:missing]).to eq([deal.id])
    expect(deal.stage_visits).to be_empty
  end
end
