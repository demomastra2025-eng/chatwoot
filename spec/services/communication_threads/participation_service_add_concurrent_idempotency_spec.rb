require 'rails_helper'

RSpec.describe CommunicationThreads::ParticipationService, '#add! concurrent idempotency' do
  self.use_transactional_tests = false

  let!(:account) { create(:account) }
  let!(:owner) { create(:user, account: account) }
  let!(:participant) { create(:user, account: account) }
  let!(:communication_thread) { create(:communication_thread, account: account, assignee: owner) }

  after do
    ActiveRecord::Base.connection.execute(
      'TRUNCATE TABLE communication_thread_participant_lifecycle_facts RESTART IDENTITY'
    )
    CommunicationThreadParticipant.where(account_id: account.id).delete_all
    CommunicationThread.where(account_id: account.id).delete_all
    Contact.where(account_id: account.id).delete_all
    AccountUser.where(account_id: account.id).delete_all
    User.where(id: [owner.id, participant.id]).delete_all
    Account.where(id: account.id).delete_all
  end

  it 'returns one membership and one fact to concurrent retries of the same operation' do
    barrier = Concurrent::CyclicBarrier.new(2)
    results = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          described_class.new(communication_thread: communication_thread, actor: owner).add!(
            user_id: participant.id,
            idempotency_key: 'concurrent-add'
          )
        end
      end
    end.map(&:value)

    expect(results.map(&:id).uniq).to contain_exactly(CommunicationThreadParticipant.find_by!(user: participant).id)
    expect(CommunicationThreadParticipantLifecycleFact.where(idempotency_key: 'concurrent-add').count).to eq(1)
  end
end
