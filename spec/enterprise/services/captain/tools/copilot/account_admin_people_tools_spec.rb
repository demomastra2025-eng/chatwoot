# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain account admin people copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user, :administrator, account: account, name: 'Owner Admin', email: 'owner@example.com') }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::CreateUserInviteService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'adds a new account user with optional team memberships' do
      team = create(:team, account: account, name: 'support')

      payload = JSON.parse(service.execute(email: 'new.operator@example.com', name: 'New Operator', role: 'agent', team_ids: team.id.to_s))
      user = User.find_by!(email: 'new.operator@example.com')

      expect(payload['action']).to eq('create_user_invite')
      expect(payload['user']).to include('id' => user.id, 'email' => 'new.operator@example.com', 'role' => 'agent')
      expect(payload['assigned_team_ids']).to eq([team.id])
      expect(team.reload.members).to include(user)
    end

    it 'rejects teams outside the assistant account' do
      other_team = create(:team, account: create(:account))

      result = service.execute(email: 'new.operator@example.com', name: 'New Operator', team_ids: other_team.id.to_s)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
      expect(User.from_email('new.operator@example.com')).to be_nil
    end
  end

  describe Captain::Tools::Copilot::UpdateUserRoleService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates an account user role' do
      operator = create(:user, account: account)

      payload = JSON.parse(service.execute(user_id: operator.id, role: 'administrator'))

      expect(payload['action']).to eq('update_user_role')
      expect(payload['user']).to include('id' => operator.id, 'role' => 'administrator')
      expect(AccountUser.find_by!(account: account, user: operator)).to be_administrator
    end

    it 'does not demote the last administrator' do
      result = service.execute(user_id: admin.id, role: 'agent')

      expect(result).to include('Cannot remove or demote the last account administrator')
      expect(AccountUser.find_by!(account: account, user: admin)).to be_administrator
    end
  end

  describe Captain::Tools::Copilot::UpdateUserAvailabilityService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates an account user availability and auto-offline setting' do
      operator = create(:user, account: account)

      payload = JSON.parse(service.execute(user_id: operator.id, availability: 'busy', auto_offline: false))

      expect(payload['action']).to eq('update_user_availability')
      expect(payload['updated_fields']).to contain_exactly('availability', 'auto_offline')
      expect(payload['user']).to include('id' => operator.id, 'availability' => 'busy', 'auto_offline' => false)
      expect(AccountUser.find_by!(account: account, user: operator)).to have_attributes(availability: 'busy', auto_offline: false)
    end

    it 'rejects users outside the assistant account' do
      other_user = create(:user, account: create(:account))

      result = service.execute(user_id: other_user.id, availability: 'offline')

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)
      service = described_class.new(assistant, user: agent)
      operator = create(:user, account: account)

      result = service.execute(user_id: operator.id, availability: 'busy')

      expect(result).to include('Account administrator permission is required')
      expect(AccountUser.find_by!(account: account, user: operator).availability).to eq('online')
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      operator = create(:user, account: account)

      payload = JSON.parse(service.execute(user_id: operator.id, availability: 'offline'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(AccountUser.find_by!(account: account, user: operator).availability).to eq('online')
    end
  end

  describe Captain::Tools::Copilot::DeactivateUserService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'removes account membership plus team and inbox memberships' do
      operator = create(:user, account: account)
      team = create(:team, account: account)
      inbox = create(:inbox, account: account)
      create(:team_member, team: team, user: operator)
      create(:inbox_member, inbox: inbox, user: operator)

      payload = JSON.parse(service.execute(user_id: operator.id))

      expect(payload['action']).to eq('deactivate_user')
      expect(payload['deactivated_user']).to include('id' => operator.id)
      expect(AccountUser.exists?(account: account, user: operator)).to be(false)
      expect(team.reload.members).to be_empty
      expect(inbox.reload.members).to be_empty
    end

    it 'rejects deactivating the current operator user' do
      result = service.execute(user_id: admin.id)

      expect(result).to include('Cannot perform this action on the current operator user')
      expect(AccountUser.exists?(account: account, user: admin)).to be(true)
    end
  end

  describe Captain::Tools::Copilot::ReactivateUserService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 're-adds an existing user to the account by email' do
      existing_user = create(:user, email: 'returning@example.com', name: 'Returning User')

      payload = JSON.parse(service.execute(email: 'returning@example.com', role: 'agent'))

      expect(payload['action']).to eq('reactivate_user')
      expect(payload['user']).to include('id' => existing_user.id, 'email' => 'returning@example.com', 'role' => 'agent')
      expect(AccountUser.exists?(account: account, user: existing_user)).to be(true)
    end
  end

  describe Captain::Tools::Copilot::AssignUserToTeamService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'assigns an account user to an account team' do
      operator = create(:user, account: account)
      team = create(:team, account: account)

      payload = JSON.parse(service.execute(user_id: operator.id, team_id: team.id))

      expect(payload['action']).to eq('assign_user_to_team')
      expect(payload['added']).to be(true)
      expect(team.reload.members).to include(operator)
    end

    it 'rejects teams outside the assistant account' do
      operator = create(:user, account: account)
      other_team = create(:team, account: create(:account))

      result = service.execute(user_id: operator.id, team_id: other_team.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
      expect(other_team.reload.members).to be_empty
    end
  end

  describe Captain::Tools::Copilot::RemoveUserFromTeamService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'removes an account user from an account team' do
      operator = create(:user, account: account)
      team = create(:team, account: account)
      create(:team_member, team: team, user: operator)

      payload = JSON.parse(service.execute(user_id: operator.id, team_id: team.id))

      expect(payload['action']).to eq('remove_user_from_team')
      expect(payload['removed']).to be(true)
      expect(team.reload.members).to be_empty
    end

    it 'rejects users outside the assistant account' do
      team = create(:team, account: account)
      other_user = create(:user, account: create(:account))

      result = service.execute(user_id: other_user.id, team_id: team.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::CreateTeamService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'creates an account team with initial members' do
      operator = create(:user, account: account)

      payload = JSON.parse(
        service.execute(name: 'VIP Support', description: 'Priority queue', allow_auto_assign: false, member_user_ids: operator.id.to_s)
      )
      team = account.teams.find(payload['team']['id'])

      expect(payload['action']).to eq('create_team')
      expect(payload['team']).to include('name' => 'vip support', 'description' => 'Priority queue', 'allow_auto_assign' => false)
      expect(team.members).to include(operator)
    end

    it 'does not mutate until the backend confirmation gate permits execution' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original

      payload = JSON.parse(service.execute(name: 'Needs Approval'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.teams.find_by(name: 'needs approval')).to be_nil
    end

    it 'rejects initial members outside the assistant account' do
      other_user = create(:user, account: create(:account))

      result = service.execute(name: 'Escalations', member_user_ids: other_user.id.to_s)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
      expect(account.teams.find_by(name: 'escalations')).to be_nil
    end
  end

  describe Captain::Tools::Copilot::UpdateTeamService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'updates account team metadata' do
      team = create(:team, account: account, name: 'old-name')

      payload = JSON.parse(service.execute(team_id: team.id, name: 'New Name', allow_auto_assign: false))

      expect(payload['action']).to eq('update_team')
      expect(payload['updated_fields']).to contain_exactly('name', 'allow_auto_assign')
      expect(team.reload.name).to eq('new name')
      expect(team.allow_auto_assign).to be(false)
    end
  end

  describe Captain::Tools::Copilot::ArchiveTeamService do
    let(:service) { described_class.new(assistant, user: admin) }

    it 'archives an account team by destroying it' do
      team = create(:team, account: account, name: 'legacy')

      payload = JSON.parse(service.execute(team_id: team.id))

      expect(payload['action']).to eq('archive_team')
      expect(payload['archived']).to be(true)
      expect(account.teams.exists?(team.id)).to be(false)
    end

    it 'rejects teams outside the assistant account' do
      other_team = create(:team, account: create(:account), name: 'external')

      result = service.execute(team_id: other_team.id)

      expect(result).to start_with('ERROR: ActiveRecord::RecordNotFound')
      expect(other_team.reload).to be_present
    end
  end

  describe 'permissions and registry exposure' do
    it 'hides write tools from non-admin operators' do
      agent = create(:user, account: account)

      expect(Captain::Tools::Copilot::CreateTeamService.new(assistant, user: agent).active?).to be(false)
      expect(Captain::Tools::Copilot::UpdateUserRoleService.new(assistant, user: agent).active?).to be(false)
    end

    it 'rejects direct non-admin execution as defense in depth' do
      agent = create(:user, account: account)
      service = Captain::Tools::Copilot::CreateTeamService.new(assistant, user: agent)

      result = service.execute(name: 'Unauthorized Team')

      expect(result).to include('Account administrator permission is required')
      expect(account.teams.find_by(name: 'unauthorized team')).to be_nil
    end

    it 'registers write tools as assistant-only high-risk confirmation tools' do
      tool_ids = %w[
        create_user_invite update_user_role update_user_availability deactivate_user reactivate_user
        assign_user_to_team remove_user_from_team create_team update_team archive_team
      ]

      tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
        expect(definition.requires_confirmation).to be(true)
        expect(definition.risk_level).to eq('high')
        expect(definition.to_h[:selected_by_default]).to be(false)
      end

      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)).not_to include(*tool_ids)
      expect(Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_ASSISTANT).pluck(:id)).to include(*tool_ids)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
