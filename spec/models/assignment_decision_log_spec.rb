require 'rails_helper'

RSpec.describe AssignmentDecisionLog do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:inbox) }
    it { is_expected.to belong_to(:conversation) }
    it { is_expected.to belong_to(:assignment_policy).optional }
    it { is_expected.to belong_to(:assigned_user).class_name('User').optional }
  end

  describe 'enum values' do
    it 'supports assigned, skipped and failed outcomes' do
      expect(described_class.outcomes.keys).to contain_exactly('assigned', 'skipped', 'failed')
    end
  end
end
