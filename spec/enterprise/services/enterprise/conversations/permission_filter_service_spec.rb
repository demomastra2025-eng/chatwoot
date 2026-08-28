require 'rails_helper'

RSpec.describe Enterprise::Conversations::PermissionFilterService do
  let(:account) { create(:account) }
  # Create conversations with different states
  let!(:assigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let!(:unassigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: nil) }
  let!(:another_assigned_conversation) { create(:conversation, account: account, inbox: inbox, assignee: create(:user, account: account)) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:inbox2) { create(:inbox, account: account) }
  let!(:another_inbox_conversation) { create(:conversation, account: account, inbox: inbox2) }

  # This inbox_member is used to establish the agent's access to the inbox
  before { create(:inbox_member, user: agent, inbox: inbox) }

  describe '#perform' do
    context 'when user is an administrator' do
      it 'returns all conversations' do
        result = Conversations::PermissionFilterService.new(
          account.conversations,
          admin,
          account
        ).perform

        expect(result).to include(assigned_conversation)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(another_assigned_conversation)
        expect(result.count).to eq(4)
      end
    end

    context 'when user is a regular agent' do
      it 'returns all account conversations regardless of inbox membership' do
        result = Conversations::PermissionFilterService.new(
          account.conversations,
          agent,
          account
        ).perform

        expect(result).to include(assigned_conversation)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(another_assigned_conversation)
        expect(result).to include(another_inbox_conversation)
        expect(result.count).to eq(4)
      end
    end

    context 'when user has conversation_manage permission' do
      # Test with a new clean state for each test case
      it 'returns all conversations' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)
        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create custom role with conversation_manage permission
        test_custom_role = create(:custom_role, account: test_account, permissions: ['conversation_manage'])
        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        unassigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        other_assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: create(:user, account: test_account))
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should have access to all messaging conversations, regardless of inbox membership.
        expect(result.count).to eq(4)
        expect(result).to include(assigned_conversation)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(other_assigned_conversation)
        expect(result).to include(other_inbox_conversation)
      end
    end

    context 'when user has conversation_participating_manage permission' do
      it 'returns conversations assigned to the agent or where the agent is a participant' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)

        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create a custom role with only the conversation_participating_manage permission
        test_custom_role = create(:custom_role, account: test_account, permissions: %w[conversation_participating_manage])

        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        other_conversation = create(:conversation, account: test_account, inbox: test_inbox)
        assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        participating_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        create(:conversation_participant, conversation: participating_conversation, account: test_account, user: test_agent)
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: test_agent)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should see conversations assigned to this agent and conversations where the agent participates.
        expect(result.count).to eq(3)
        expect(result).to include(assigned_conversation)
        expect(result).to include(participating_conversation)
        expect(result).not_to include(other_conversation)
        expect(result).to include(other_inbox_conversation)
      end
    end

    context 'when user has conversation_unassigned_manage permission' do
      it 'returns unassigned conversations AND mine' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)

        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create a custom role with only the conversation_unassigned_manage permission
        test_custom_role = create(:custom_role, account: test_account, permissions: %w[conversation_unassigned_manage])

        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        unassigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        other_assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: create(:user, account: test_account))
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should see unassigned conversations AND conversations assigned to this agent
        expect(result.count).to eq(3)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(assigned_conversation)

        # Should NOT include conversations assigned to others
        expect(result).not_to include(other_assigned_conversation)
        expect(result).to include(other_inbox_conversation)
      end
    end

    context 'when a custom role has no conversation permissions' do
      it 'returns no conversations' do
        custom_role = create(:custom_role, account: account, permissions: [])
        account.account_users.find_by!(user: agent).update!(custom_role: custom_role)

        result = Conversations::PermissionFilterService.new(account.conversations, agent, account).perform

        expect(result).to be_empty
      end
    end

    context 'when a custom role can manage conversations in a Voice inbox' do
      it 'keeps Voice conversations readable without inbox membership' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
        account.account_users.find_by!(user: agent).update!(custom_role: custom_role)
        voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
        voice_conversation = create(:conversation, account: account, inbox: voice_inbox)

        service = -> { Conversations::PermissionFilterService.new(account.conversations, agent, account).perform }

        expect(service.call).to include(voice_conversation)
      end

      it 'keeps Voice mutations scoped to inbox membership' do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_manage'])
        account.account_users.find_by!(user: agent).update!(custom_role: custom_role)
        voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
        voice_conversation = create(:conversation, account: account, inbox: voice_inbox)
        service = Conversations::PermissionFilterService.new(account.conversations, agent, account)

        expect(service.perform_operational).not_to include(voice_conversation)

        create(:inbox_member, user: agent, inbox: voice_inbox)

        expect(service.perform_operational).to include(voice_conversation)
      end
    end

    context 'when user has both participating and unassigned permissions (hierarchical test)' do
      it 'gives higher priority to unassigned_manage over participating_manage' do
        # Create a new isolated test environment
        test_account = create(:account)
        test_inbox = create(:inbox, account: test_account)
        test_inbox2 = create(:inbox, account: test_account)

        # Create test agent
        test_agent = create(:user, account: test_account, role: :agent)
        create(:inbox_member, user: test_agent, inbox: test_inbox)

        # Create a custom role with both participating and unassigned permissions
        permissions = %w[conversation_participating_manage conversation_unassigned_manage]
        test_custom_role = create(:custom_role, account: test_account, permissions: permissions)

        account_user = AccountUser.find_by(user: test_agent, account: test_account)
        account_user.update(role: :agent, custom_role: test_custom_role)

        # Create some conversations
        assigned_to_agent = create(:conversation, account: test_account, inbox: test_inbox, assignee: test_agent)
        unassigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: nil)
        other_assigned_conversation = create(:conversation, account: test_account, inbox: test_inbox, assignee: create(:user, account: test_account))
        other_inbox_conversation = create(:conversation, account: test_account, inbox: test_inbox2, assignee: nil)

        # Run the test
        result = Conversations::PermissionFilterService.new(
          test_account.conversations,
          test_agent,
          test_account
        ).perform

        # Should behave the same as conversation_unassigned_manage test
        # - Show both unassigned and assigned to this agent
        # - Do not show conversations assigned to others
        expect(result.count).to eq(3)
        expect(result).to include(unassigned_conversation)
        expect(result).to include(assigned_to_agent)
        expect(result).not_to include(other_assigned_conversation)
        expect(result).to include(other_inbox_conversation)
      end
    end
  end
end
