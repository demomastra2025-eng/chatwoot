require 'rails_helper'

RSpec.describe AutoAssignment::AssignmentJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:agent) { create(:user, account: account, role: :agent, availability: :online) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
  end

  describe '.enqueue' do
    let(:dedup_token) { 'assignment-dedup-token' }
    let(:dedup_key) { format(Redis::Alfred::AUTO_ASSIGNMENT_JOB_QUEUED, inbox_id: inbox.id) }

    before do
      allow(SecureRandom).to receive(:uuid).and_return(dedup_token)
    end

    it 'queues at most one pending job per inbox' do
      expect(Redis::Alfred).to receive(:set)
        .with(dedup_key, dedup_token, nx: true, ex: described_class::QUEUED_LEASE_TTL)
        .and_return(true)

      expect do
        described_class.enqueue(inbox_id: inbox.id)
      end.to have_enqueued_job(described_class).with(inbox_id: inbox.id, dedup_token: dedup_token)
    end

    it 'coalesces a duplicate request while a job is already pending' do
      allow(Redis::Alfred).to receive(:set).with(
        dedup_key,
        dedup_token,
        nx: true,
        ex: described_class::QUEUED_LEASE_TTL
      ).and_return(false)

      expect do
        expect(described_class.enqueue(inbox_id: inbox.id)).to be(false)
      end.not_to have_enqueued_job(described_class)
    end

    it 'releases the pending lease when enqueueing fails' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(described_class).to receive(:perform_later).and_raise(RedisClient::ConnectionError, 'redis unavailable')
      expect(Redis::Alfred).to receive(:delete_if_value).with(dedup_key, dedup_token)

      expect do
        described_class.enqueue(inbox_id: inbox.id)
      end.to raise_error(RedisClient::ConnectionError, 'redis unavailable')
    end

    it 'releases the pending lease when Active Job reports a rejected enqueue' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(described_class).to receive(:perform_later).and_return(false)
      expect(Redis::Alfred).to receive(:delete_if_value).with(dedup_key, dedup_token)

      expect do
        described_class.enqueue(inbox_id: inbox.id)
      end.to raise_error(ActiveJob::EnqueueError, "Failed to enqueue auto assignment for inbox #{inbox.id}")
    end
  end

  describe '#perform' do
    context 'when inbox exists' do
      context 'when auto assignment is enabled' do
        it 'calls the assignment service' do
          service = instance_double(AutoAssignment::AssignmentService)
          allow(AutoAssignment::AssignmentService).to receive(:new).with(inbox: inbox).and_return(service)
          expect(service).to receive(:perform_bulk_assignment).with(limit: 100).and_return(5)

          described_class.new.perform(inbox_id: inbox.id)
        end

        it 'logs the assignment count' do
          service = instance_double(AutoAssignment::AssignmentService)
          allow(AutoAssignment::AssignmentService).to receive(:new).and_return(service)
          allow(service).to receive(:perform_bulk_assignment).and_return(3)

          expect(Rails.logger).to receive(:info).with("Assigned 3 conversations for inbox #{inbox.id}")

          described_class.new.perform(inbox_id: inbox.id)
        end

        it 'uses custom bulk limit from environment' do
          allow(ENV).to receive(:fetch).with('AUTO_ASSIGNMENT_BULK_LIMIT', 100).and_return('50')

          service = instance_double(AutoAssignment::AssignmentService)
          allow(AutoAssignment::AssignmentService).to receive(:new).with(inbox: inbox).and_return(service)
          expect(service).to receive(:perform_bulk_assignment).with(limit: 50).and_return(2)

          described_class.new.perform(inbox_id: inbox.id)
        end

        it 'does not overlap another bulk assignment for the same inbox' do
          allow(Redis::Alfred).to receive(:set).and_return(false)
          expect(AutoAssignment::AssignmentService).not_to receive(:new)
          expect(described_class).to receive(:enqueue).with(inbox_id: inbox.id, wait: described_class::OVERLAP_RETRY_DELAY)

          described_class.new.perform(inbox_id: inbox.id, dedup_token: 'queued-token')
        end

        it 'coalesces persisted legacy payloads before acquiring the runtime lease' do
          legacy_key = described_class.legacy_drain_key(inbox.id)
          allow(Redis::Alfred).to receive(:set)
            .with(legacy_key, kind_of(String), nx: true, ex: described_class::LEGACY_DRAIN_LEASE_TTL)
            .and_return(false)
          expect(AutoAssignment::AssignmentService).not_to receive(:new)

          described_class.new.perform(inbox_id: inbox.id)
        end
      end

      context 'when auto assignment is disabled' do
        before { inbox.update!(enable_auto_assignment: false) }

        it 'calls the service which handles the disabled state' do
          service = instance_double(AutoAssignment::AssignmentService)
          allow(AutoAssignment::AssignmentService).to receive(:new).with(inbox: inbox).and_return(service)
          expect(service).to receive(:perform_bulk_assignment).with(limit: 100).and_return(0)

          described_class.new.perform(inbox_id: inbox.id)
        end
      end
    end

    context 'when inbox does not exist' do
      it 'returns early without processing' do
        expect(AutoAssignment::AssignmentService).not_to receive(:new)

        described_class.new.perform(inbox_id: 999_999)
      end
    end

    context 'when an error occurs' do
      it 'logs the error and re-raises so Sidekiq retry policy can recover' do
        service = instance_double(AutoAssignment::AssignmentService)
        allow(AutoAssignment::AssignmentService).to receive(:new).and_return(service)
        allow(service).to receive(:perform_bulk_assignment).and_raise(StandardError, 'Something went wrong')

        expect(Rails.logger).to receive(:error).with("Bulk assignment failed for inbox #{inbox.id}: Something went wrong")

        expect do
          described_class.new.perform(inbox_id: inbox.id)
        end.to raise_error(StandardError, 'Something went wrong')
      end
    end
  end

  describe 'job configuration' do
    it 'is queued in the isolated auto assignment queue' do
      expect(described_class.queue_name).to eq('auto_assignment')
    end
  end
end
