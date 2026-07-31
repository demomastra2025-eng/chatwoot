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
      expect(payload['lifecycle_snapshot_id']).to be_present
      expect(payload['idempotent_replay']).to be(false)
      expect(AccountUser.exists?(account: account, user: operator)).to be(false)
      expect(team.reload.members).to be_empty
      expect(inbox.reload.members).to be_empty
    end

    it 'returns the active lifecycle snapshot when deactivation is repeated' do
      operator = create(:user, account: account)

      first_payload = JSON.parse(service.execute(user_id: operator.id))
      replay_payload = JSON.parse(service.execute(user_id: operator.id))

      expect(replay_payload).to include(
        'action' => 'deactivate_user_already_inactive',
        'idempotent_replay' => true,
        'lifecycle_snapshot_id' => first_payload['lifecycle_snapshot_id']
      )
      expect(AccountUserLifecycleSnapshot.active.where(account: account, user: operator).count).to eq(1)
    end

    it 'refreshes the active snapshot when membership was manually recreated before another deactivation' do
      operator = create(:user, account: account)
      first_payload = JSON.parse(service.execute(user_id: operator.id))
      new_team = create(:team, account: account)
      AccountUser.create!(account: account, user: operator, role: 'agent', availability: 'busy')
      create(:team_member, team: new_team, user: operator)

      second_payload = JSON.parse(service.execute(user_id: operator.id))
      snapshot = AccountUserLifecycleSnapshot.find(first_payload['lifecycle_snapshot_id'])

      expect(second_payload).to include(
        'action' => 'deactivate_user',
        'lifecycle_snapshot_id' => first_payload['lifecycle_snapshot_id'],
        'idempotent_replay' => false
      )
      expect(snapshot).to have_attributes(availability: 'busy', team_ids: [new_team.id])
      expect(AccountUserLifecycleSnapshot.active.where(account: account, user: operator).count).to eq(1)
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

    it 'restores the saved workspace and protects it from the stale destroy job' do
      operator = create(:user, account: account, email: 'restorable@example.com')
      account_user = AccountUser.find_by!(account: account, user: operator)
      custom_role = create(:custom_role, account: account)
      capacity_policy = create(:agent_capacity_policy, account: account)
      account_user.update!(
        role: 'administrator',
        availability: 'busy',
        auto_offline: false,
        custom_role: custom_role,
        agent_capacity_policy: capacity_policy
      )
      team = create(:team, account: account)
      inbox = create(:inbox, account: account)
      create(:team_member, team: team, user: operator)
      create(:inbox_member, inbox: inbox, user: operator)

      deactivate_payload = JSON.parse(
        Captain::Tools::Copilot::DeactivateUserService.new(assistant, user: admin).execute(user_id: operator.id)
      )
      reactivate_payload = JSON.parse(service.execute(lifecycle_snapshot_id: deactivate_payload['lifecycle_snapshot_id']))
      restored_account_user = AccountUser.find_by!(account: account, user: operator)

      expect(reactivate_payload).to include(
        'action' => 'reactivate_user',
        'workspace_restored' => true,
        'restored_team_ids' => [team.id],
        'restored_inbox_ids' => [inbox.id],
        'lifecycle_snapshot_id' => deactivate_payload['lifecycle_snapshot_id'],
        'reactivation_source' => 'lifecycle_snapshot_id'
      )
      expect(restored_account_user).to have_attributes(
        role: 'administrator',
        availability: 'busy',
        auto_offline: false,
        custom_role_id: custom_role.id,
        agent_capacity_policy_id: capacity_policy.id
      )
      expect(team.reload.members).to include(operator)
      expect(inbox.reload.members).to include(operator)

      Agents::DestroyJob.perform_now(account, operator)

      expect(team.reload.members).to include(operator)
      expect(inbox.reload.members).to include(operator)
      expect(operator.notification_settings.exists?(account_id: account.id)).to be(true)

      replay_payload = JSON.parse(service.execute(lifecycle_snapshot_id: deactivate_payload['lifecycle_snapshot_id']))
      expect(replay_payload).to include('action' => 'reactivate_user_already_active', 'idempotent_replay' => true)
      expect(AccountUserLifecycleSnapshot.find(deactivate_payload['lifecycle_snapshot_id']).reactivated_at).to be_present
    end

    it 'reactivates by stable user ID and rejects identities from another account' do
      operator = create(:user, account: account, email: 'stable-id@example.com')
      deactivate_payload = JSON.parse(
        Captain::Tools::Copilot::DeactivateUserService.new(assistant, user: admin).execute(user_id: operator.id)
      )

      payload = JSON.parse(service.execute(user_id: deactivate_payload['user_id']))

      expect(payload).to include(
        'action' => 'reactivate_user',
        'reactivation_source' => 'user_id',
        'lifecycle_snapshot_id' => deactivate_payload['lifecycle_snapshot_id']
      )

      other_user = create(:user, account: create(:account))
      expect(service.execute(user_id: other_user.id)).to start_with('ERROR: ActiveRecord::RecordNotFound')

      other_snapshot = AccountUserLifecycleSnapshot.create!(
        account: other_user.accounts.first,
        user: other_user,
        role: 'agent',
        availability: 'offline',
        deactivated_at: Time.current
      )
      expect(service.execute(lifecycle_snapshot_id: other_snapshot.id)).to start_with('ERROR: ActiveRecord::RecordNotFound')
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
