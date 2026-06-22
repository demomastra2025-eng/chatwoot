require 'rails_helper'

RSpec.describe AssignmentClientOwnership do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:contact) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:assignment_policy).optional }
  end

  describe '#active?' do
    it 'is active when expires_at is blank or in the future' do
      expect(build(:assignment_client_ownership, expires_at: nil)).to be_active
      expect(build(:assignment_client_ownership, expires_at: 1.hour.from_now)).to be_active
      expect(build(:assignment_client_ownership, expires_at: 1.hour.ago)).not_to be_active
    end
  end
end
