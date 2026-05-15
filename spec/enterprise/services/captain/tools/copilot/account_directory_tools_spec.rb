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

  describe 'registry exposure' do
    it 'exposes account directory tools only to the operator assistant scope' do
      account_user_definition = Captain::ToolRegistry.definition_for('list_account_users')
      teams_definition = Captain::ToolRegistry.definition_for('list_teams')

      expect(account_user_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(teams_definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include('list_account_users', 'list_teams')
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include('list_account_users', 'list_teams')
      expect(account_user_definition.to_h[:selected_by_default]).to be(false)
      expect(teams_definition.to_h[:selected_by_default]).to be(false)
    end
  end
end
