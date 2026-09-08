require 'rails_helper'

RSpec.describe Crm::StageVisit do
  let(:deal) { create(:crm_deal) }

  it 'allows only one active visit per deal' do
    create(:crm_stage_visit, deal: deal)

    expect { create(:crm_stage_visit, deal: deal) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'rejects an interval that exits before entry' do
    visit = build(:crm_stage_visit, deal: deal, entered_at: Time.current, exited_at: 1.minute.ago)

    expect(visit).not_to be_valid
    expect(visit.errors[:exited_at]).to include('must not be before entered_at')
  end

  it 'allows one close but rejects later mutation or deletion' do
    visit = create(:crm_stage_visit, deal: deal)
    visit.update!(exited_at: Time.current)

    expect { visit.update!(stage_name: 'Rewritten') }.to raise_error(ActiveRecord::RecordNotSaved)
    expect(visit.destroy).to be false
    expect(visit.reload).to be_persisted
  end
end
