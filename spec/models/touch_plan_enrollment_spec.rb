require 'rails_helper'

RSpec.describe TouchPlanEnrollment do
  subject(:enrollment) { build(:touch_plan_enrollment) }

  it { is_expected.to be_valid }

  it 'rejects cross-account remindables' do
    enrollment.remindable = create(:scheduling_appointment, account: create(:account))

    expect(enrollment).not_to be_valid
    expect(enrollment.errors[:remindable]).to include('must belong to the same account')
  end

  it 'preserves an audit row when the remindable is removed' do
    enrollment.save!

    enrollment.remindable.destroy!

    expect(enrollment.reload.remindable).to be_nil
  end
end
