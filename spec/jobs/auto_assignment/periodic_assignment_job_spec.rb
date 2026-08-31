require 'rails_helper'

RSpec.describe AutoAssignment::PeriodicAssignmentJob, type: :job do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:assignment_policy) { create(:assignment_policy, account: account) }
  let(:inbox_assignment_policy) { create(:inbox_assignment_policy, inbox: inbox, assignment_policy: assignment_policy) }
  let(:agent) { create(:user, account: account, role: :agent) }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
  end

  describe '#perform' do
    context 'when account has assignment_v2 feature enabled' do
      before do
        account.enable_features('assignment_v2')
        account.save!
        allow(Account).to receive(:find_in_batches).and_yield([account])
      end

      context 'when auto assignment is enabled' do
        it 'queues assignment job for eligible inboxes' do
          inbox_assignment_policy # ensure it exists
          expect(AutoAssignment::AssignmentJob).to receive(:enqueue).with(inbox_id: inbox.id)

          described_class.new.perform
        end

        it 'queues assignment job even when the inbox has no assignment policy' do
          InboxAssignmentPolicy.where(inbox: inbox).destroy_all
          expect(AutoAssignment::AssignmentJob).to receive(:enqueue).with(inbox_id: inbox.id)

          described_class.new.perform
        end

        it 'processes multiple accounts' do
          inbox_assignment_policy # ensure it exists
          account2 = create(:account)
          inbox2 = create(:inbox, account: account2, enable_auto_assignment: true)
          policy2 = create(:assignment_policy, account: account2)
          create(:inbox_assignment_policy, inbox: inbox2, assignment_policy: policy2)

          account2.enable_features('assignment_v2')
          account2.save!

          allow(Account).to receive(:find_in_batches).and_yield([account]).and_yield([account2])

          expect(AutoAssignment::AssignmentJob).to receive(:enqueue).with(inbox_id: inbox.id)
          expect(AutoAssignment::AssignmentJob).to receive(:enqueue).with(inbox_id: inbox2.id)

          described_class.new.perform
        end

        it 'skips auto assignment when account is on the default cloud plan' do
          account.update!(custom_attributes: {})
          create(:installation_config, name: 'CHATWOOT_CLOUD_PLANS', value: [{ 'name' => 'default' }])
          allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)
          allow(Rails.logger).to receive(:info)

          expect(Rails.logger).to receive(:info).with("Skipping auto assignment for account #{account.id}")
          expect(AutoAssignment::AssignmentJob).not_to receive(:enqueue)

          described_class.new.perform
        end
      end

      context 'when auto assignment is disabled' do
        before do
          inbox.update!(enable_auto_assignment: false)
          InboxAssignmentPolicy.where(inbox: inbox).destroy_all
        end

        it 'does not queue assignment job' do
          expect(AutoAssignment::AssignmentJob).not_to receive(:enqueue)

          described_class.new.perform
        end
      end
    end

    context 'when account does not have assignment_v2 feature enabled' do
      before do
        allow(Account).to receive(:find_in_batches).and_yield([account])
      end

      it 'does not process the account' do
        expect(AutoAssignment::AssignmentJob).not_to receive(:enqueue)

        described_class.new.perform
      end
    end

    context 'with batch processing' do
      it 'processes accounts in batches' do
        accounts = []
        # Create multiple accounts
        5.times do |_i|
          acc = create(:account)
          acc.enable_features('assignment_v2')
          acc.save!
          create(:inbox, account: acc, enable_auto_assignment: true)
          policy = create(:assignment_policy, account: acc)
          create(:inbox_assignment_policy, inbox: acc.inboxes.first, assignment_policy: policy)

          accounts << acc
        end

        allow(Account).to receive(:find_in_batches) do |&block|
          accounts.each { |acc| block.call([acc]) }
        end

        expect(AutoAssignment::AssignmentJob).to receive(:enqueue).exactly(5).times

        described_class.new.perform
      end
    end
  end

  describe 'job configuration' do
    it 'is queued in the scheduled_jobs queue' do
      expect(described_class.queue_name).to eq('scheduled_jobs')
    end
  end
end
