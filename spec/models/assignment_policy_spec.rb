require 'rails_helper'

RSpec.describe AssignmentPolicy do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:inbox_assignment_policies).dependent(:destroy) }
    it { is_expected.to have_many(:inboxes).through(:inbox_assignment_policies) }
    it { is_expected.to have_many(:assignment_client_ownerships).dependent(:nullify) }
    it { is_expected.to have_many(:assignment_quota_usages).dependent(:nullify) }
    it { is_expected.to have_many(:assignment_decision_logs).dependent(:nullify) }
  end

  describe 'validations' do
    subject { build(:assignment_policy) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:account_id) }
  end

  describe 'fair distribution validations' do
    it 'requires fair_distribution_limit to be greater than 0' do
      policy = build(:assignment_policy, fair_distribution_limit: 0)
      expect(policy).not_to be_valid
      expect(policy.errors[:fair_distribution_limit]).not_to be_empty
    end

    it 'requires fair_distribution_window to be greater than 0' do
      policy = build(:assignment_policy, fair_distribution_window: -1)
      expect(policy).not_to be_valid
      expect(policy.errors[:fair_distribution_window]).not_to be_empty
    end
  end

  describe 'load policy validations' do
    it 'requires assignment_delay_minutes to be zero or greater' do
      policy = build(:assignment_policy, assignment_delay_minutes: -1)
      expect(policy).not_to be_valid
      expect(policy.errors[:assignment_delay_minutes]).not_to be_empty
    end

    it 'allows optional max_open_conversations but validates positive values' do
      expect(build(:assignment_policy, max_open_conversations: nil)).to be_valid

      policy = build(:assignment_policy, max_open_conversations: 0)
      expect(policy).not_to be_valid
      expect(policy.errors[:max_open_conversations]).not_to be_empty
    end

    it 'allows optional monthly_new_client_quota but validates positive values' do
      expect(build(:assignment_policy, monthly_new_client_quota: nil)).to be_valid

      policy = build(:assignment_policy, monthly_new_client_quota: 0)
      expect(policy).not_to be_valid
      expect(policy.errors[:monthly_new_client_quota]).not_to be_empty
    end

    it 'requires sticky_owner_duration_days to be greater than 0' do
      policy = build(:assignment_policy, sticky_owner_duration_days: 0)
      expect(policy).not_to be_valid
      expect(policy.errors[:sticky_owner_duration_days]).not_to be_empty
    end
  end

  describe 'enum values' do
    let(:assignment_policy) { create(:assignment_policy) }

    describe 'conversation_priority' do
      it 'can be set to earliest_created' do
        assignment_policy.update!(conversation_priority: :earliest_created)
        expect(assignment_policy.conversation_priority).to eq('earliest_created')
        expect(assignment_policy.earliest_created?).to be true
      end

      it 'can be set to longest_waiting' do
        assignment_policy.update!(conversation_priority: :longest_waiting)
        expect(assignment_policy.conversation_priority).to eq('longest_waiting')
        expect(assignment_policy.longest_waiting?).to be true
      end
    end

    describe 'assignment_order' do
      it 'can be set to round_robin' do
        assignment_policy.update!(assignment_order: :round_robin)
        expect(assignment_policy.assignment_order).to eq('round_robin')
        expect(assignment_policy.round_robin?).to be true
      end
    end
  end
end
