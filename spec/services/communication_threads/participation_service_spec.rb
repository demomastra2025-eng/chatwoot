# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::ParticipationService do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:participant) { create(:user, account: account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:communication_thread) { conversation.reload.communication_thread || conversation.refresh_communication_thread! }
  let(:service) { described_class.new(communication_thread: communication_thread, actor: owner) }

  before do
    account.enable_features!('communication_threads')
    communication_thread.update!(assignee: owner)
  end

  describe '#add!' do
    it 'creates one canonical membership, activity and realtime update' do
      realtime_jobs_before = enqueued_jobs.count { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }

      expect do
        service.add!(user_id: participant.id)
      end.to change(CommunicationThreadParticipant, :count).by(1)

      membership = communication_thread.communication_thread_participants.find_by!(user: participant)
      expect(membership.added_by).to eq(owner)
      expect(membership.audits.last.comment).to eq('manual_add')
      expect(conversation.messages.activity.count).to eq(1)
      expect(enqueued_jobs.count { |job| job[:job] == CommunicationThreads::RealtimeUpdateJob }).to be > realtime_jobs_before
      expect(conversation.messages.activity.last.content_attributes).to include('communication_thread_participation')
    end

    it 'is idempotent' do
      service.add!(user_id: participant.id)

      expect { service.add!(user_id: participant.id) }
        .not_to change(CommunicationThreadParticipant, :count)
    end

    it 'does not allow the owner to also be a participant' do
      expect { service.add!(user_id: owner.id) }
        .to raise_error(ArgumentError, 'assignee cannot also be a participant')
    end

    it 'rejects an invited workspace user who has not activated the account' do
      invited_user = create(:user, account: account, skip_confirmation: false)

      expect { service.add!(user_id: invited_user.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '#remove!' do
    it 'removes the membership and notifies the removed user through realtime' do
      service.add!(user_id: participant.id)
      clear_enqueued_jobs
      allow(CommunicationThreads::AfterCommit).to receive(:run).and_yield

      expect { service.remove!(user_id: participant.id) }
        .to change(CommunicationThreadParticipant, :count).by(-1)
      expect(CommunicationThreads::RealtimeUpdateJob).to have_been_enqueued.with(
        hash_including(recipient_user_ids: [participant.id])
      )
    end

    it 'does not publish realtime when an outer transaction rolls back' do
      service.add!(user_id: participant.id)
      clear_enqueued_jobs

      CommunicationThreadParticipant.transaction(requires_new: true) do
        service.remove!(user_id: participant.id)
        raise ActiveRecord::Rollback
      end

      expect(communication_thread.communication_thread_participants).to exist(user_id: participant.id)
      expect(CommunicationThreads::RealtimeUpdateJob).not_to have_been_enqueued
    end

    it 'does not publish resolution cleanup when the status transaction rolls back' do
      service.add!(user_id: participant.id)
      clear_enqueued_jobs

      CommunicationThread.transaction(requires_new: true) do
        communication_thread.update!(status: :resolved)
        raise ActiveRecord::Rollback
      end

      expect(communication_thread.reload).to be_open
      expect(communication_thread.communication_thread_participants).to exist(user_id: participant.id)
      expect(CommunicationThreads::RealtimeUpdateJob).not_to have_been_enqueued
    end
  end
end
