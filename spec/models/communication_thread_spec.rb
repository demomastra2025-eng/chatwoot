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
    it { is_expected.to have_many(:meta_ad_referrals).dependent(:nullify) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:contact_id) }
  end

  describe '.of_person' do
    let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }

    it 'finds the thread of the person and no other', :aggregate_failures do
      conversation = create(:conversation, account: account)
      thread = conversation.reload.communication_thread
      stranger = create(:contact, account: account)

      expect(described_class.of_person(account_id: account.id, contact_id: conversation.contact_id)).to eq(thread)
      expect(described_class.of_person(account_id: account.id, contact_id: stranger.id)).to be_nil
      expect(described_class.of_person(account_id: create(:account).id, contact_id: conversation.contact_id)).to be_nil
    end
  end

  describe '.snoozed_until_for' do
    let(:account) { create(:account) }
    let(:contact) { create(:contact, account: account) }

    def conversation_with(status:, snoozed_until: nil)
      conversation = create(:conversation, account: account, contact: contact, status: :open)
      conversation.update!(status: status, snoozed_until: snoozed_until)
      conversation
    end

    it 'returns the earliest wake-up time among the snoozed channels' do
      later = conversation_with(status: :snoozed, snoozed_until: 3.days.from_now.change(usec: 0))
      earlier = conversation_with(status: :snoozed, snoozed_until: 1.day.from_now.change(usec: 0))
      open_one = conversation_with(status: :open)

      expect(described_class.snoozed_until_for([later, earlier, open_one])).to eq(earlier.snoozed_until)
    end

    it 'ignores channels snoozed until the next reply and channels that are not snoozed' do
      next_reply = conversation_with(status: :snoozed)
      open_one = conversation_with(status: :open)

      expect(described_class.snoozed_until_for([next_reply, open_one])).to be_nil
    end

    it 'returns nil without conversations' do
      expect(described_class.snoozed_until_for([])).to be_nil
    end
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
