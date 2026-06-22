require 'rails_helper'

RSpec.describe AssignmentQuotaUsage do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:contact) }
    it { is_expected.to belong_to(:conversation).optional }
    it { is_expected.to belong_to(:assignment_policy).optional }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:period_start) }
    it { is_expected.to validate_presence_of(:period_end) }
  end
end
