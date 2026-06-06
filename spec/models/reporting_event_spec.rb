require 'rails_helper'

RSpec.describe ReportingEvent do
  describe 'validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:value) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:inbox).optional }
    it { is_expected.to belong_to(:user).optional }
    it { is_expected.to belong_to(:conversation).optional }

    it 'remains conversation-centric and does not bind metrics to communication threads' do
      expect(described_class.reflect_on_association(:communication_thread)).to be_nil
      expect(described_class.column_names).not_to include('communication_thread_id')
    end
  end
end
