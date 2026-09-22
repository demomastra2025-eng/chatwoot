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

  describe 'terminal lifecycle facts' do
    let(:account) { create(:account) }
    let(:participant) { create(:user, account: account) }
    let(:communication_thread) { create(:communication_thread, account: account) }

    it 'records a system removal before its thread is destroyed' do
      membership = create(:communication_thread_participant, account: account, communication_thread: communication_thread, user: participant)

      communication_thread.destroy!

      expect(CommunicationThreadParticipantLifecycleFact.find_by!(participant_id: participant.id)).to have_attributes(
        communication_thread_id: membership.communication_thread_id,
        action: 'remove',
        reason: 'thread_deleted',
        actor_kind: 'system'
      )
    end

    it 'records a system removal synchronously before its user is destroyed' do
      membership = create(:communication_thread_participant, account: account, communication_thread: communication_thread, user: participant)

      participant.destroy!

      expect(CommunicationThreadParticipantLifecycleFact.find_by!(participant_id: membership.user_id)).to have_attributes(
        action: 'remove',
        reason: 'user_deleted',
        actor_kind: 'system'
      )
    end
  end
end
