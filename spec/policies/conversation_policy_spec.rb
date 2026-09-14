require 'rails_helper'

RSpec.describe ConversationPolicy, type: :policy do
  subject { described_class }

  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:administrator_context) { { user: administrator, account: account, account_user: administrator.account_users.find_by(account: account) } }
  let(:agent_context) { { user: agent, account: account, account_user: agent.account_users.find_by(account: account) } }

  let(:conversation) { create(:conversation, account: account) }

  permissions :destroy? do
    context 'when user is an administrator' do
      it 'allows destroy' do
        expect(subject).to permit(administrator_context, conversation)
      end
    end

    context 'when user is an agent' do
      it 'denies destroy' do
        expect(subject).not_to permit(agent_context, conversation)
      end
    end
  end

  permissions :index? do
    context 'when user is authenticated' do
      it 'allows index' do
        expect(subject).to permit(agent_context, conversation)
      end
    end
  end

  permissions :show? do
    context 'when user is an administrator' do
      it 'allows access' do
        expect(subject).to permit(administrator_context, conversation)
      end
    end

    context 'when agent belongs to the account' do
      let(:inbox) { create(:inbox, account: account) }
      let(:conversation) { create(:conversation, account: account, inbox: inbox) }

      it 'allows access without inbox membership' do
        expect(subject).to permit(agent_context, conversation)
      end
    end

    context 'when conversation belongs to a Voice inbox' do
      let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
      let(:conversation) { create(:conversation, account: account, inbox: voice_inbox) }

      it 'allows an account agent without Voice inbox membership' do
        expect(subject).to permit(agent_context, conversation)
      end

      it 'allows an administrator without Voice inbox membership' do
        expect(subject).to permit(administrator_context, conversation)
      end
    end

    context 'when conversation belongs to another account' do
      let(:conversation) { create(:conversation, account: create(:account)) }

      it 'denies access' do
        expect(subject).not_to permit(agent_context, conversation)
      end
    end

    context 'when communication thread access roles are enforced' do
      let(:other_agent) { create(:user, account: account, role: :agent) }
      let(:conversation) { create(:conversation, account: account, assignee: other_agent) }

      before do
        account.enable_features!('communication_threads')
        AccessControl::SystemRoleBootstrapper.call(account: account)
        restricted_role = create(:access_role, account: account)
        create(
          :access_role_grant,
          account: account,
          access_role: restricted_role,
          resource: 'conversations',
          capability: 'view',
          access_scope: 'own'
        )
        agent.account_users.find_by!(account: account).update!(access_role: restricted_role)
        account.authorize_access_control_mode_transition do
          account.update!(access_control_mode: :enforced)
        end
      end

      it 'denies the direct conversation API outside canonical thread scope' do
        expect(subject).not_to permit(agent_context, conversation)
      end

      it 'allows the direct conversation API for a canonical participant' do
        create(
          :communication_thread_participant,
          account: account,
          communication_thread: conversation.reload.communication_thread,
          user: agent
        )

        expect(subject).to permit(agent_context, conversation)
      end
    end
  end
end
