# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThread do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:contact) }
    it { is_expected.to belong_to(:assignee).optional }
    it { is_expected.to belong_to(:team).optional }
    it { is_expected.to have_many(:communication_thread_conversations).dependent(:destroy) }
    it { is_expected.to have_many(:conversations).through(:communication_thread_conversations) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:contact_id) }
  end

  describe 'display id' do
    it 'assigns a durable display id on create' do
      thread = create(:communication_thread)

      expect(thread.display_id).to be_present
      expect(thread.display_id).to be_positive
    end

    it 'keeps display id unique inside an account' do
      account = create(:account)
      first_thread = create(:communication_thread, account: account)
      duplicate = build(
        :communication_thread,
        account: account,
        contact: create(:contact, account: account),
        display_id: first_thread.display_id
      )

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:display_id]).to be_present
    end
  end
end
