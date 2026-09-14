# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreadParticipant do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:communication_thread) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:added_by).optional }
  end

  describe 'account boundaries' do
    let(:account) { create(:account) }
    let(:communication_thread) { create(:communication_thread, account: account) }

    it 'accepts a workspace member from the same account' do
      participant = build(
        :communication_thread_participant,
        communication_thread: communication_thread,
        account: account,
        user: create(:user, account: account)
      )

      expect(participant).to be_valid
    end

    it 'rejects a user from another account' do
      participant = build(
        :communication_thread_participant,
        communication_thread: communication_thread,
        account: account,
        user: create(:user, account: create(:account))
      )

      expect(participant).not_to be_valid
      expect(participant.errors[:user]).to include('must be an active workspace member')
    end

    it 'rejects an actor from another account' do
      participant = build(
        :communication_thread_participant,
        communication_thread: communication_thread,
        account: account,
        user: create(:user, account: account),
        added_by: create(:user, account: create(:account))
      )

      expect(participant).not_to be_valid
      expect(participant.errors[:added_by]).to include('must belong to the same account')
    end
  end
end
