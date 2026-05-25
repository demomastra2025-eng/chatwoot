# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Captain account directory copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user, :administrator, account: account) }

  describe Captain::Tools::Copilot::ListAccountUsersService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists account users with safe assignment metadata and excludes other accounts' do
      support_user = create(:user, account: account, name: 'Support Aida', email: 'aida@example.com')
      other_user = create(:user, account: create(:account), name: 'Other User')
      team = create(:team, account: account, name: 'sales')
      create(:team_member, team: team, user: support_user)

      payload = JSON.parse(service.execute(query: 'aida'))

      expect(payload['total_count']).to eq(1)
      expect(payload['users']).to contain_exactly(
        include(
          'id' => support_user.id,
          'name' => 'Support Aida',
          'email' => 'aida@example.com',
          'role' => 'agent',
          'availability' => 'online',
          'auto_offline' => true,
          'team_ids' => [team.id]
        )
      )
      expect(payload['users'].pluck('id')).not_to include(other_user.id)
    end

    it 'is hidden when the current user has no relevant account permissions' do
      viewer = create(:user, account: account)
      custom_role = create(:custom_role, account: account, permissions: ['knowledge_base_manage'])
      AccountUser.find_by!(account: account, user: viewer).update!(custom_role: custom_role)

      expect(described_class.new(assistant, user: viewer).active?).to be(false)
    end

    it 'is hidden from default non-admin agents without an explicit people-directory permission' do
      agent = create(:user, account: account)

      expect(described_class.new(assistant, user: agent).active?).to be(false)
    end

    it 'is visible to custom-role operators with assignment-management permissions' do
      manager = create(:user, account: account)
      custom_role = create(:custom_role, account: account, permissions: ['crm_task_manage'])
      AccountUser.find_by!(account: account, user: manager).update!(custom_role: custom_role)

      expect(described_class.new(assistant, user: manager).active?).to be(true)
    end
  end

  describe Captain::Tools::Copilot::ListTeamsService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists account teams with members and excludes other accounts' do
      member = create(:user, account: account, name: 'Manager Dana', email: 'dana@example.com')
      team = create(:team, account: account, name: 'support', description: 'Main queue')
      other_team = create(:team, account: create(:account), name: 'external')
      create(:team_member, team: team, user: member)

      payload = JSON.parse(service.execute(query: 'support'))

      expect(payload['total_count']).to eq(1)
      expect(payload['teams']).to contain_exactly(
        include(
          'id' => team.id,
          'name' => 'support',
          'description' => 'Main queue',
          'allow_auto_assign' => true,
          'members' => [include('id' => member.id, 'name' => 'Manager Dana', 'email' => 'dana@example.com')]
        )
      )
      expect(payload['teams'].pluck('id')).not_to include(other_team.id)
    end

    it 'can omit members when only team IDs are needed' do
      create(:team, account: account, name: 'sales')

      payload = JSON.parse(service.execute(include_members: false))

      expect(payload['teams'].first).not_to have_key('members')
    end

    it 'is hidden from default non-admin agents without an explicit people-directory permission' do
      agent = create(:user, account: account)

      expect(described_class.new(assistant, user: agent).active?).to be(false)
    end
  end

  describe Captain::Tools::Copilot::ListInboxesService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists account inbox routing metadata and excludes other accounts' do
      inbox = create(:inbox, account: account, name: 'WhatsApp Sales', timezone: 'Asia/Almaty', working_hours_enabled: true)
      other_inbox = create(:inbox, account: create(:account), name: 'External Inbox')
      policy = create(:assignment_policy, account: account, name: 'Sales Round Robin')
      create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant, auto_reply_mode: CaptainInbox::AUTO_REPLY_WORKING_HOURS)

      payload = JSON.parse(service.execute(query: 'sales'))

      expect(payload['total_count']).to eq(1)
      expect(payload['inboxes']).to contain_exactly(
        include(
          'id' => inbox.id,
          'name' => 'WhatsApp Sales',
          'channel_type' => 'Channel::WebWidget',
          'timezone' => 'Asia/Almaty',
          'enable_auto_assignment' => true,
          'working_hours_enabled' => true,
          'assignment_policy' => include('id' => policy.id, 'name' => 'Sales Round Robin', 'enabled' => true),
          'captain' => include(
            'enabled' => true,
            'assistant_id' => assistant.id,
            'assistant_name' => assistant.name,
            'auto_reply_mode' => CaptainInbox::AUTO_REPLY_WORKING_HOURS,
            'available_auto_reply_modes' => CaptainInbox::AUTO_REPLY_MODES
          )
        )
      )
      expect(payload['inboxes'].pluck('id')).not_to include(other_inbox.id)
    end

    it 'filters by Captain connection state and rejects direct non-admin execution' do
      create(:inbox, account: account, name: 'Manual Inbox')
      connected = create(:inbox, account: account, name: 'Captain Inbox')
      create(:captain_inbox, inbox: connected, captain_assistant: assistant)

      payload = JSON.parse(service.execute(captain_enabled: true))
      agent = create(:user, account: account)

      expect(payload['inboxes'].pluck('id')).to contain_exactly(connected.id)
      expect(described_class.new(assistant, user: agent).active?).to be(false)
      expect(described_class.new(assistant, user: agent).execute).to include('ERROR:')
    end
  end

  describe Captain::Tools::Copilot::ListAssignmentPoliciesService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'lists account assignment policies with attached inboxes and excludes other accounts' do
      inbox = create(:inbox, account: account, name: 'Support Inbox')
      policy = create(:assignment_policy, account: account, name: 'Support Policy', description: 'Support routing')
      other_policy = create(:assignment_policy, account: create(:account), name: 'External Policy')
      foreign_inbox = create(:inbox, account: other_policy.account, name: 'Foreign Inbox')
      create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
      create(:inbox_assignment_policy, inbox: foreign_inbox, assignment_policy: policy)

      payload = JSON.parse(service.execute(query: 'support'))

      expect(payload['total_count']).to eq(1)
      expect(payload['assignment_policies']).to contain_exactly(
        include(
          'id' => policy.id,
          'name' => 'Support Policy',
          'description' => 'Support routing',
          'enabled' => true,
          'assignment_order' => 'round_robin',
          'conversation_priority' => 'earliest_created',
          'fair_distribution_limit' => 10,
          'fair_distribution_window' => 3600,
          'inbox_ids' => [inbox.id],
          'inboxes' => [include('id' => inbox.id, 'name' => 'Support Inbox', 'channel_type' => 'Channel::WebWidget')]
        )
      )
      expect(payload['assignment_policies'].pluck('id')).not_to include(other_policy.id)
    end

    it 'filters by enabled state and rejects direct non-admin execution' do
      enabled_policy = create(:assignment_policy, account: account, name: 'Enabled Policy', enabled: true)
      create(:assignment_policy, account: account, name: 'Disabled Policy', enabled: false)
      agent = create(:user, account: account)

      payload = JSON.parse(service.execute(enabled: true))

      expect(payload['assignment_policies'].pluck('id')).to contain_exactly(enabled_policy.id)
      expect(described_class.new(assistant, user: agent).active?).to be(false)
      expect(described_class.new(assistant, user: agent).execute).to include('ERROR:')
    end
  end

  describe 'registry exposure' do
    it 'exposes account directory tools only to the operator assistant scope' do
      account_user_definition = Captain::ToolRegistry.definition_for('list_account_users')
      teams_definition = Captain::ToolRegistry.definition_for('list_teams')
      inboxes_definition = Captain::ToolRegistry.definition_for('list_inboxes')
      assignment_policies_definition = Captain::ToolRegistry.definition_for('list_assignment_policies')
      directory_tool_ids = %w[list_account_users list_teams list_inboxes list_assignment_policies]

      expect(account_user_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(teams_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(inboxes_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(assignment_policies_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*directory_tool_ids)
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*directory_tool_ids)
      expect(account_user_definition.to_h[:selected_by_default]).to be(false)
      expect(teams_definition.to_h[:selected_by_default]).to be(false)
      expect(inboxes_definition.to_h).to include(risk_level: 'low', idempotent: true, selected_by_default: false)
      expect(assignment_policies_definition.to_h).to include(risk_level: 'low', idempotent: true, selected_by_default: false)
    end
  end
end
