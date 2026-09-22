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
    it 'creates one canonical membership, immutable fact, activity and realtime update' do
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
      fact = CommunicationThreadParticipantLifecycleFact.last
      expect(fact).to have_attributes(
        account_id: account.id,
        communication_thread_id: communication_thread.id,
        participant_type: 'User',
        participant_id: participant.id,
        actor_kind: 'user',
        actor_type: 'User',
        actor_id: owner.id,
        action: 'add',
        reason: 'manual_add',
        reliable_since: fact.occurred_at,
        schema_version: 1
      )
    end

    it 'is idempotent for the same operation identity' do
      correlation_id = SecureRandom.uuid
      service.add!(user_id: participant.id, idempotency_key: 'same-add', correlation_id: correlation_id)

      expect do
        service.add!(user_id: participant.id, idempotency_key: 'same-add', correlation_id: correlation_id)
      end.to not_change(CommunicationThreadParticipant, :count)
        .and not_change(CommunicationThreadParticipantLifecycleFact, :count)
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
    it 'removes the membership, records a fact and notifies the removed user through realtime' do
      service.add!(user_id: participant.id)
      clear_enqueued_jobs
      allow(CommunicationThreads::AfterCommit).to receive(:run).and_yield

      expect { service.remove!(user_id: participant.id) }
        .to change(CommunicationThreadParticipant, :count).by(-1)
      expect(CommunicationThreads::RealtimeUpdateJob).to have_been_enqueued.with(
        hash_including(recipient_user_ids: [participant.id])
      )
      expect(CommunicationThreadParticipantLifecycleFact.order(:id).last).to have_attributes(
        action: 'remove', reason: 'manual_remove', participant_id: participant.id
      )
    end

    it 'records remove and re-add as separate ordered occurrences' do
      service.add!(user_id: participant.id, idempotency_key: 'first-add')
      service.remove!(user_id: participant.id, idempotency_key: 'remove')
      service.add!(user_id: participant.id, idempotency_key: 'second-add')

      expect(CommunicationThreadParticipantLifecycleFact.order(:id).pluck(:action, :idempotency_key)).to eq(
        [%w[add first-add], %w[remove remove], %w[add second-add]]
      )
      facts = CommunicationThreadParticipantLifecycleFact.order(:id)
      expect(facts.second.reliable_since).to eq(facts.first.reliable_since)
      expect(facts.third.reliable_since).to eq(facts.third.occurred_at)
    end

    it 'marks removal of a legacy membership as lacking a reliable duration boundary' do
      create(:communication_thread_participant, account: account, communication_thread: communication_thread, user: participant)

      service.remove!(user_id: participant.id, reason: 'legacy_cleanup')

      expect(CommunicationThreadParticipantLifecycleFact.last.reliable_since).to be_nil
    end

    it 'does not repeat a removal for a retried idempotency identity' do
      service.add!(user_id: participant.id)
      service.remove!(user_id: participant.id, idempotency_key: 'same-remove')

      expect do
        service.remove!(user_id: participant.id, idempotency_key: 'same-remove')
      end.not_to change(CommunicationThreadParticipantLifecycleFact, :count)
    end

    it 'treats a retry after a successful removal without a caller key as a no-op' do
      service.add!(user_id: participant.id)
      service.remove!(user_id: participant.id)

      expect { service.remove!(user_id: participant.id) }
        .not_to change(CommunicationThreadParticipantLifecycleFact, :count)
    end

    it 'rejects reuse of an idempotency identity for a different lifecycle operation' do
      second = create(:user, account: account)
      service.add!(user_id: participant.id, idempotency_key: 'operation-key')

      expect do
        service.add!(user_id: second.id, idempotency_key: 'operation-key')
      end.to raise_error(ArgumentError, /already used/)
      expect(communication_thread.communication_thread_participants).not_to exist(user_id: second.id)
    end

    it 'does not publish facts or realtime when an outer transaction rolls back' do
      service.add!(user_id: participant.id)
      clear_enqueued_jobs

      CommunicationThreadParticipant.transaction(requires_new: true) do
        service.remove!(user_id: participant.id)
        raise ActiveRecord::Rollback
      end

      expect(communication_thread.communication_thread_participants).to exist(user_id: participant.id)
      expect(CommunicationThreadParticipantLifecycleFact.where(action: 'remove')).to be_empty
      expect(CommunicationThreads::RealtimeUpdateJob).not_to have_been_enqueued
    end

    it 'does not publish resolution facts or realtime when the status transaction rolls back' do
      service.add!(user_id: participant.id)
      clear_enqueued_jobs

      CommunicationThread.transaction(requires_new: true) do
        communication_thread.update!(status: :resolved)
        raise ActiveRecord::Rollback
      end

      expect(communication_thread.reload).to be_open
      expect(communication_thread.communication_thread_participants).to exist(user_id: participant.id)
      expect(CommunicationThreadParticipantLifecycleFact.where(action: 'resolve')).to be_empty
      expect(CommunicationThreads::RealtimeUpdateJob).not_to have_been_enqueued
    end
  end

  describe 'lifecycle action semantics' do
    before do
      service.add!(user_id: participant.id)
    end

    it 'records clear, retain, promotion and resolution actions explicitly', :aggregate_failures do
      second = create(:user, account: account)
      service.add!(user_id: second.id)
      service.retain!(user_ids: [participant.id], reason: 'cross_team_transfer')
      service.remove!(user_id: participant.id, reason: 'promoted_to_owner')
      service.add!(user_id: participant.id)
      service.clear!(reason: 'participants_cleared')
      service.add!(user_id: participant.id)
      service.clear!(reason: 'thread_resolved')

      expect(CommunicationThreadParticipantLifecycleFact.order(:id).pluck(:action)).to include(
        'retain', 'promote', 'clear', 'resolve'
      )
    end
  end

  describe 'actor identity' do
    it 'captures system, customer and Captain actors without a polymorphic association', :aggregate_failures do
      described_class.new(communication_thread: communication_thread, actor: nil).add!(user_id: participant.id)
      described_class.new(communication_thread: communication_thread, actor: nil).remove!(user_id: participant.id)
      customer = create(:contact, account: account)
      described_class.new(communication_thread: communication_thread, actor: customer).add!(user_id: participant.id)
      described_class.new(communication_thread: communication_thread, actor: customer).remove!(user_id: participant.id)
      assistant = create(:captain_assistant, account: account)
      described_class.new(communication_thread: communication_thread, actor: assistant).add!(user_id: participant.id)

      identities = CommunicationThreadParticipantLifecycleFact.order(:id).pluck(:actor_kind, :actor_type, :actor_id)
      expect(identities).to include(['system', 'System', nil])
      expect(identities).to include(['customer', 'Contact', customer.id])
      expect(identities).to include(['captain', 'Captain::Assistant', assistant.id])
    end

    it 'rejects an actor from another account without writing membership or fact' do
      outsider = create(:user, account: create(:account))
      foreign_service = described_class.new(communication_thread: communication_thread, actor: outsider)

      expect { foreign_service.add!(user_id: participant.id) }.to raise_error(ActiveRecord::RecordNotFound)
      expect(communication_thread.communication_thread_participants).to be_empty
      expect(CommunicationThreadParticipantLifecycleFact.count).to eq(0)
    end
  end
end
