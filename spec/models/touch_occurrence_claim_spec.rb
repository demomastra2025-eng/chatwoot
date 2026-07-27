require 'rails_helper'

RSpec.describe TouchOccurrenceClaim do
  subject(:claim) { build(:touch_occurrence_claim) }

  it { is_expected.to be_valid }

  it 'allows only one occurrence per enrollment' do
    claim.save!
    duplicate = build(
      :touch_occurrence_claim,
      account: claim.account,
      touch_plan_enrollment: claim.touch_plan_enrollment,
      occurrence_key: claim.occurrence_key
    )

    expect(duplicate).not_to be_valid
  end

  it 'rejects a reminder from another account' do
    claim.reminder = create(:reminder, account: create(:account))

    expect(claim).not_to be_valid
    expect(claim.errors[:reminder]).to include('must belong to the same account')
  end
end
