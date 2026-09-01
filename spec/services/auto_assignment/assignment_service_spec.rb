require 'rails_helper'

RSpec.describe AutoAssignment::AssignmentService do
  let(:account) { create(:account) }
  let(:assignment_policy) { create(:assignment_policy, account: account, enabled: true) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:service) { described_class.new(inbox: inbox) }
  let(:agent) { create(:user, account: account, role: :agent, availability: :online) }
  let(:agent2) { create(:user, account: account, role: :agent, availability: :online) }
  let(:conversation) { create(:conversation, inbox: inbox, assignee: nil) }

  before do
    # Enable assignment_v2 feature for the account (basic assignment features)
    account.enable_features('assignment_v2')
    account.save!
    # Link inbox to assignment policy
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: assignment_policy)
    create(:inbox_member, inbox: inbox, user: agent)
  end

  describe '#perform_bulk_assignment' do
    context 'when auto assignment is enabled' do
      let(:rate_limiter) { instance_double(AutoAssignment::RateLimiter) }

      before do
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })

        # Mock RoundRobinSelector to return the agent
        round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
        allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
        allow(round_robin_selector).to receive(:select_agent).and_return(agent)

        # Mock RateLimiter to allow all assignments by default
        allow(AutoAssignment::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(rate_limiter).to receive(:within_limit?).and_return(true)
        allow(rate_limiter).to receive(:track_assignment)
      end

      it 'assigns conversations to available agents' do
        # Create conversation and ensure it's unassigned
        conv = create(:conversation, inbox: inbox, status: 'open')
        conv.update!(assignee_id: nil)

        assigned_count = service.perform_bulk_assignment(limit: 1)

        expect(assigned_count).to eq(1)
        expect(conv.reload.assignee).to eq(agent)
      end

      it 'assigns conversations when no assignment policy is linked' do
        InboxAssignmentPolicy.where(inbox: inbox).destroy_all
        conv = create(:conversation, inbox: inbox, status: 'open')
        conv.update!(assignee_id: nil)

        assigned_count = service.perform_bulk_assignment(limit: 1)

        expect(assigned_count).to eq(1)
        expect(conv.reload.assignee).to eq(agent)
      end

      it 'returns 0 when no agents are online' do
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
        expect(service).not_to receive(:unassigned_conversations)

        assigned_count = service.perform_bulk_assignment(limit: 1)

        expect(assigned_count).to eq(0)
        expect(conversation.reload.assignee).to be_nil
      end

      it 'assigns to inbox members regardless of presence when online-only is disabled' do
        assignment_policy.update!(assign_online_only: false)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'busy' })
        conv = create(:conversation, inbox: inbox, status: 'open', assignee: nil)

        assigned_count = service.perform_bulk_assignment(limit: 1)

        expect(assigned_count).to eq(1)
        expect(conv.reload.assignee).to eq(agent)
      end

      it 'does not override a conversation assigned by another worker before the claim' do
        competing_agent = create(:user, account: account, role: :agent, availability: :online)
        conv = create(:conversation, inbox: inbox, status: 'open', assignee: nil)

        expect do
          allow(service).to receive(:unassigned_conversations).and_return([conv])
          allow(service).to receive(:find_available_agent).and_wrap_original do |original, current_conversation|
            conv.update_columns(assignee_id: competing_agent.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
            original.call(current_conversation)
          end

          assigned_count = service.perform_bulk_assignment(limit: 1)

          expect(assigned_count).to eq(0)
        end.to change(AssignmentDecisionLog, :count).by(1)

        failed_log = AssignmentDecisionLog.last
        expect(failed_log).to have_attributes(
          conversation_id: conv.id,
          outcome: 'failed',
          reasons: ['conversation_claim_failed']
        )
        expect(failed_log.decision_metadata).to include('assigned_user_id' => agent.id)
        expect(conv.reload.assignee).to eq(competing_agent)
        expect(rate_limiter).not_to have_received(:track_assignment)
        expect(Current.executed_by).to be_nil
      end

      it 'does not override a conversation assigned by another worker before the claim without a policy' do
        InboxAssignmentPolicy.where(inbox: inbox).destroy_all
        competing_agent = create(:user, account: account, role: :agent, availability: :online)
        conv = create(:conversation, inbox: inbox, status: 'open', assignee: nil)

        allow(service).to receive(:unassigned_conversations).and_return([conv])
        allow(service).to receive(:find_available_agent).and_wrap_original do |original, current_conversation|
          conv.update_columns(assignee_id: competing_agent.id, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          original.call(current_conversation)
        end

        assigned_count = service.perform_bulk_assignment(limit: 1)

        expect(assigned_count).to eq(0)
        expect(conv.reload.assignee).to eq(competing_agent)
        expect(rate_limiter).not_to have_received(:track_assignment)
        expect(Current.executed_by).to be_nil
      end

      it 'respects the limit parameter' do
        3.times do
          conv = create(:conversation, inbox: inbox, status: 'open')
          conv.update!(assignee_id: nil)
        end

        assigned_count = service.perform_bulk_assignment(limit: 2)

        expect(assigned_count).to eq(2)
        expect(inbox.conversations.unassigned.count).to eq(1)
      end

      it 'only assigns open conversations' do
        conversation # ensure it exists
        conversation.update!(assignee_id: nil)
        resolved_conversation = create(:conversation, inbox: inbox, status: 'resolved')
        resolved_conversation.update!(assignee_id: nil)
        pending_conversation = create(:conversation, inbox: inbox, status: 'pending', assignee: nil)

        service.perform_bulk_assignment(limit: 10)

        expect(conversation.reload.assignee).to eq(agent)
        expect(resolved_conversation.reload.assignee).to be_nil
        expect(pending_conversation.reload.assignee).to be_nil
      end

      it 'does not reassign already assigned conversations' do
        conversation # ensure it exists
        conversation.update!(assignee_id: nil)
        assigned_conversation = create(:conversation, inbox: inbox, assignee: agent)
        unassigned_conversation = create(:conversation, inbox: inbox, status: 'open')
        unassigned_conversation.update!(assignee_id: nil)

        assigned_count = service.perform_bulk_assignment(limit: 10)

        expect(assigned_count).to eq(2) # conversation + unassigned_conversation
        expect(assigned_conversation.reload.assignee).to eq(agent)
        expect(unassigned_conversation.reload.assignee).to eq(agent)
      end

      it 'dispatches assignee changed event' do
        conversation # ensure it exists
        conversation.update!(assignee_id: nil)

        # The conversation model also dispatches a conversation.updated event
        allow(Rails.configuration.dispatcher).to receive(:dispatch)
        expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
          Events::Types::ASSIGNEE_CHANGED,
          anything,
          hash_including(conversation: conversation, user: agent)
        )

        service.perform_bulk_assignment(limit: 1)
      end
    end

    context 'when auto assignment is disabled' do
      before { assignment_policy.update!(enabled: false) }

      it 'returns 0 without processing' do
        assigned_count = service.perform_bulk_assignment(limit: 10)

        expect(assigned_count).to eq(0)
        expect(conversation.reload.assignee).to be_nil
      end
    end

    context 'with conversation priority' do
      let(:rate_limiter) { instance_double(AutoAssignment::RateLimiter) }

      before do
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ agent.id.to_s => 'online' })

        # Mock RoundRobinSelector to return the agent
        round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
        allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
        allow(round_robin_selector).to receive(:select_agent).and_return(agent)

        # Mock RateLimiter to allow all assignments by default
        allow(AutoAssignment::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(rate_limiter).to receive(:within_limit?).and_return(true)
        allow(rate_limiter).to receive(:track_assignment)
      end

      context 'when priority is longest_waiting' do
        before do
          assignment_policy.update!(conversation_priority: :longest_waiting)
        end

        it 'assigns conversations with oldest last_activity_at first' do
          old_conversation = create(:conversation,
                                    inbox: inbox,
                                    status: 'open',
                                    created_at: 2.hours.ago,
                                    last_activity_at: 2.hours.ago)
          old_conversation.update!(assignee_id: nil)
          new_conversation = create(:conversation,
                                    inbox: inbox,
                                    status: 'open',
                                    created_at: 1.hour.ago,
                                    last_activity_at: 1.hour.ago)
          new_conversation.update!(assignee_id: nil)

          service.perform_bulk_assignment(limit: 1)

          expect(old_conversation.reload.assignee).to eq(agent)
          expect(new_conversation.reload.assignee).to be_nil
        end
      end

      context 'when priority is default' do
        it 'assigns conversations by created_at' do
          old_conversation = create(:conversation, inbox: inbox, status: 'open', created_at: 2.hours.ago)
          old_conversation.update!(assignee_id: nil)
          new_conversation = create(:conversation, inbox: inbox, status: 'open', created_at: 1.hour.ago)
          new_conversation.update!(assignee_id: nil)

          service.perform_bulk_assignment(limit: 1)

          expect(old_conversation.reload.assignee).to eq(agent)
          expect(new_conversation.reload.assignee).to be_nil
        end
      end
    end

    context 'with fair distribution' do
      before do
        create(:inbox_member, inbox: inbox, user: agent2)
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({
                                                                                 agent.id.to_s => 'online',
                                                                                 agent2.id.to_s => 'online'
                                                                               })
      end

      context 'when fair distribution is enabled' do
        before do
          allow(inbox).to receive(:auto_assignment_config).and_return({
                                                                        'fair_distribution_limit' => 2,
                                                                        'fair_distribution_window' => 3600
                                                                      })
        end

        it 'respects the assignment limit per agent' do
          # Mock RoundRobinSelector to select agent2
          round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
          allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
          allow(round_robin_selector).to receive(:select_agent).and_return(agent2)

          # Mock agent1 at limit, agent2 not at limit
          agent1_limiter = instance_double(AutoAssignment::RateLimiter)
          agent2_limiter = instance_double(AutoAssignment::RateLimiter)

          allow(AutoAssignment::RateLimiter).to receive(:new).with(inbox: inbox, agent: agent).and_return(agent1_limiter)
          allow(AutoAssignment::RateLimiter).to receive(:new).with(inbox: inbox, agent: agent2).and_return(agent2_limiter)

          allow(agent1_limiter).to receive(:within_limit?).and_return(false)
          allow(agent2_limiter).to receive(:within_limit?).and_return(true)
          allow(agent2_limiter).to receive(:track_assignment)

          unassigned_conversation = create(:conversation, inbox: inbox, status: 'open')
          unassigned_conversation.update!(assignee_id: nil)

          service.perform_bulk_assignment(limit: 1)

          expect(unassigned_conversation.reload.assignee).to eq(agent2)
        end

        it 'tracks assignments in Redis' do
          conversation # ensure it exists
          conversation.update!(assignee_id: nil)

          # Mock RoundRobinSelector
          round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
          allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
          allow(round_robin_selector).to receive(:select_agent).and_return(agent)

          limiter = instance_double(AutoAssignment::RateLimiter)
          allow(AutoAssignment::RateLimiter).to receive(:new).and_return(limiter)
          allow(limiter).to receive(:within_limit?).and_return(true)
          expect(limiter).to receive(:track_assignment)

          service.perform_bulk_assignment(limit: 1)
        end

        it 'allows assignments after window expires' do
          # Mock RoundRobinSelector
          round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
          allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
          allow(round_robin_selector).to receive(:select_agent).and_return(agent, agent2)

          # Mock RateLimiter to allow all
          limiter = instance_double(AutoAssignment::RateLimiter)
          allow(AutoAssignment::RateLimiter).to receive(:new).and_return(limiter)
          allow(limiter).to receive(:within_limit?).and_return(true)
          allow(limiter).to receive(:track_assignment)

          # Simulate time passing for rate limit window
          freeze_time do
            2.times do
              conversation_new = create(:conversation, inbox: inbox, status: 'open')
              conversation_new.update!(assignee_id: nil)
              service.perform_bulk_assignment(limit: 1)
              expect(conversation_new.reload.assignee).not_to be_nil
            end
          end

          # Move forward past the window
          travel_to(2.hours.from_now) do
            new_conversation = create(:conversation, inbox: inbox, status: 'open')
            new_conversation.update!(assignee_id: nil)
            service.perform_bulk_assignment(limit: 1)
            expect(new_conversation.reload.assignee).not_to be_nil
          end
        end
      end

      context 'when fair distribution is disabled' do
        it 'assigns without rate limiting' do
          5.times do
            conv = create(:conversation, inbox: inbox, status: 'open')
            conv.update!(assignee_id: nil)
          end

          # Mock RoundRobinSelector
          round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
          allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
          allow(round_robin_selector).to receive(:select_agent).and_return(agent)

          # Mock RateLimiter to allow all
          limiter = instance_double(AutoAssignment::RateLimiter)
          allow(AutoAssignment::RateLimiter).to receive(:new).and_return(limiter)
          allow(limiter).to receive(:within_limit?).and_return(true)
          allow(limiter).to receive(:track_assignment)

          assigned_count = service.perform_bulk_assignment(limit: 5)
          expect(assigned_count).to eq(5)
        end
      end

      context 'with round robin assignment' do
        it 'distributes conversations evenly among agents' do
          conversations = Array.new(4) { create(:conversation, inbox: inbox, assignee: nil) }

          service.perform_bulk_assignment(limit: 4)

          agent1_count = conversations.count { |c| c.reload.assignee == agent }
          agent2_count = conversations.count { |c| c.reload.assignee == agent2 }

          # Should be distributed evenly (2 each) or close to even (3 and 1)
          expect([agent1_count, agent2_count].sort).to eq([2, 2]).or(eq([1, 3]))
        end
      end
    end

    context 'with team assignments' do
      let(:team) { create(:team, account: account, allow_auto_assign: true) }
      let(:team_member) { create(:user, account: account, role: :agent, availability: :online) }
      let(:rate_limiter) { instance_double(AutoAssignment::RateLimiter) }

      before do
        create(:team_member, team: team, user: team_member)
        create(:inbox_member, inbox: inbox, user: team_member)

        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({ team_member.id.to_s => 'online' })

        allow(AutoAssignment::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(rate_limiter).to receive(:within_limit?).and_return(true)
        allow(rate_limiter).to receive(:track_assignment)

        round_robin_selector = instance_double(AutoAssignment::RoundRobinSelector)
        allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
        allow(round_robin_selector).to receive(:select_agent).and_return(team_member)
      end

      it 'assigns conversation with team to team member' do
        conversation_with_team = create(:conversation, inbox: inbox, team: team, assignee: nil)

        service.perform_bulk_assignment(limit: 1)

        expect(conversation_with_team.reload.assignee).to eq(team_member)
      end

      it 'skips assignment when team has allow_auto_assign false' do
        team.update!(allow_auto_assign: false)
        conversation_with_team = create(:conversation, inbox: inbox, team: team, assignee: nil)

        service.perform_bulk_assignment(limit: 1)

        expect(conversation_with_team.reload.assignee).to be_nil
      end

      it 'skips assignment when no team members are available' do
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
        conversation_with_team = create(:conversation, inbox: inbox, team: team, assignee: nil)

        service.perform_bulk_assignment(limit: 1)

        expect(conversation_with_team.reload.assignee).to be_nil
      end
    end

    context 'with load policy controls' do
      let(:rate_limiter) { instance_double(AutoAssignment::RateLimiter, within_limit?: true, track_assignment: true) }
      let(:round_robin_selector) { instance_double(AutoAssignment::RoundRobinSelector) }

      before do
        allow(OnlineStatusTracker).to receive(:get_available_users).and_return({
                                                                                 agent.id.to_s => 'online',
                                                                                 agent2.id.to_s => 'online'
                                                                               })
        create(:inbox_member, inbox: inbox, user: agent2)
        allow(AutoAssignment::RateLimiter).to receive(:new).and_return(rate_limiter)
        allow(AutoAssignment::RoundRobinSelector).to receive(:new).and_return(round_robin_selector)
      end

      it 'waits until assignment_delay_minutes has elapsed' do
        assignment_policy.update!(assignment_delay_minutes: 30)
        young_conversation = create(:conversation, inbox: inbox, status: 'open', created_at: 10.minutes.ago, assignee: nil)
        ready_conversation = create(:conversation, inbox: inbox, status: 'open', created_at: 40.minutes.ago, assignee: nil)

        allow(round_robin_selector).to receive(:select_agent).and_return(agent)

        assigned_count = service.perform_bulk_assignment(limit: 10)

        expect(assigned_count).to eq(1)
        expect(young_conversation.reload.assignee).to be_nil
        expect(ready_conversation.reload.assignee).to eq(agent)
      end

      it 'assigns pending conversations after AI handoff only when the policy toggle and delay allow it' do
        assignment_policy.update!(assign_pending_conversations: true, assignment_delay_minutes: 30)
        young_pending_conversation = create(:conversation, inbox: inbox, status: 'pending', created_at: 10.minutes.ago, assignee: nil)
        ready_pending_conversation = create(:conversation, inbox: inbox, status: 'pending', created_at: 40.minutes.ago, assignee: nil)

        allow(round_robin_selector).to receive(:select_agent).and_return(agent)

        assigned_count = service.perform_bulk_assignment(limit: 10)

        expect(assigned_count).to eq(1)
        expect(young_pending_conversation.reload.assignee).to be_nil
        expect(ready_pending_conversation.reload.assignee).to eq(agent)
        expect(ready_pending_conversation).to be_pending
      end

      it 'skips agents that reached max_open_conversations' do
        assignment_policy.update!(max_open_conversations: 1)
        create(:conversation, inbox: inbox, status: 'open', assignee: agent)
        candidate_conversation = create(:conversation, inbox: inbox, status: 'open', assignee: nil)

        allow(round_robin_selector).to receive(:select_agent) do |members|
          members.map(&:user).detect { |user| user == agent2 }
        end

        service.perform_bulk_assignment(limit: 1)

        expect(candidate_conversation.reload.assignee).to eq(agent2)
        expect(AssignmentDecisionLog.last.candidate_summaries).to include(
          hash_including('user_id' => agent.id, 'reasons' => include('max_open_conversations_reached'))
        )
      end

      it 'counts assigned pending conversations toward max_open_conversations when pending assignment is enabled' do
        assignment_policy.update!(assign_pending_conversations: true, max_open_conversations: 1)
        create(:conversation, inbox: inbox, status: 'pending', assignee: agent)
        candidate_conversation = create(:conversation, inbox: inbox, status: 'pending', assignee: nil)

        allow(round_robin_selector).to receive(:select_agent) do |members|
          members.map(&:user).detect { |user| user == agent2 }
        end

        service.perform_bulk_assignment(limit: 1)

        expect(candidate_conversation.reload.assignee).to eq(agent2)
        expect(candidate_conversation).to be_pending
        expect(AssignmentDecisionLog.last.candidate_summaries).to include(
          hash_including('user_id' => agent.id, 'reasons' => include('max_open_conversations_reached'))
        )
      end

      it 'skips agents that reached monthly_new_client_quota and records idempotent quota usage' do
        assignment_policy.update!(monthly_new_client_quota: 1)
        existing_contact = create(:contact, account: account)
        create(:assignment_quota_usage, account: account, user: agent, contact: existing_contact, assignment_policy: assignment_policy)
        candidate_conversation = create(:conversation, inbox: inbox, status: 'open', assignee: nil)

        allow(round_robin_selector).to receive(:select_agent) do |members|
          members.map(&:user).detect { |user| user == agent2 }
        end

        expect do
          service.perform_bulk_assignment(limit: 1)
        end.to change(AssignmentQuotaUsage, :count).by(1)

        expect(candidate_conversation.reload.assignee).to eq(agent2)
        expect(AssignmentQuotaUsage.last.user).to eq(agent2)
        expect(AssignmentDecisionLog.last.candidate_summaries).to include(
          hash_including('user_id' => agent.id, 'reasons' => include('monthly_new_client_quota_reached'))
        )
      end

      it 'routes a known contact to the central contact owner even without sticky policy' do
        known_contact = create(:contact, account: account, owner: agent2)
        owner_conversation = create(:conversation, inbox: inbox, contact: known_contact, status: 'open', assignee: nil)
        owner_conversation.update_columns(assignee_id: nil) # rubocop:disable Rails/SkipsModelValidations

        expect(round_robin_selector).not_to receive(:select_agent)

        service.perform_bulk_assignment(limit: 1)

        expect(owner_conversation.reload.assignee).to eq(agent2)
      end

      it 'falls back to the current inbox policy when the central owner is not an inbox member' do
        other_inbox = create(:inbox, account: account)
        other_inbox_owner = create(:user, account: account, role: :agent, availability: :online)
        create(:inbox_member, inbox: other_inbox, user: other_inbox_owner)
        known_contact = create(:contact, account: account, owner: other_inbox_owner)
        other_conversation = create(:conversation, inbox: other_inbox, contact: known_contact, status: 'open', assignee: nil)
        current_inbox_conversation = create(:conversation, inbox: inbox, contact: known_contact, status: 'open', assignee: nil)
        current_inbox_conversation.update_columns(assignee_id: nil) # rubocop:disable Rails/SkipsModelValidations

        allow(round_robin_selector).to receive(:select_agent).and_return(agent)

        service.perform_bulk_assignment(limit: 1)

        expect(current_inbox_conversation.reload.assignee).to eq(agent)
        expect(known_contact.reload.owner).to eq(other_inbox_owner)
        expect(other_conversation.reload.assignee).to eq(other_inbox_owner)
      end

      it 'routes a known contact to an available sticky owner' do
        assignment_policy.update!(sticky_owner_enabled: true, sticky_owner_duration_days: 15)
        known_contact = create(:contact, account: account)
        create(:assignment_client_ownership,
               account: account,
               contact: known_contact,
               user: agent2,
               assignment_policy: assignment_policy,
               expires_at: 1.day.from_now)
        sticky_conversation = create(:conversation, inbox: inbox, contact: known_contact, status: 'open', assignee: nil)

        expect(round_robin_selector).not_to receive(:select_agent)

        service.perform_bulk_assignment(limit: 1)

        expect(sticky_conversation.reload.assignee).to eq(agent2)
      end

      it 'ignores sticky owner when the owner is not an eligible candidate' do
        assignment_policy.update!(sticky_owner_enabled: true)
        offline_owner = create(:user, account: account, role: :agent, availability: :offline)
        known_contact = create(:contact, account: account)
        create(:assignment_client_ownership,
               account: account,
               contact: known_contact,
               user: offline_owner,
               assignment_policy: assignment_policy,
               expires_at: 1.day.from_now)
        sticky_conversation = create(:conversation, inbox: inbox, contact: known_contact, status: 'open', assignee: nil)

        allow(round_robin_selector).to receive(:select_agent).and_return(agent)

        service.perform_bulk_assignment(limit: 1)

        expect(sticky_conversation.reload.assignee).to eq(agent)
      end

      it 'writes a skipped decision log when no candidate is eligible' do
        assignment_policy.update!(max_open_conversations: 1)
        create(:conversation, inbox: inbox, status: 'open', assignee: agent)
        create(:conversation, inbox: inbox, status: 'open', assignee: agent2)
        blocked_conversation = create(:conversation, inbox: inbox, status: 'open', assignee: nil)

        assigned_count = service.perform_bulk_assignment(limit: 1)

        expect(assigned_count).to eq(0)
        expect(blocked_conversation.reload.assignee).to be_nil
        expect(AssignmentDecisionLog.last).to have_attributes(
          conversation_id: blocked_conversation.id,
          outcome: 'skipped',
          reasons: ['no_eligible_agents']
        )
      end
    end
  end
end
