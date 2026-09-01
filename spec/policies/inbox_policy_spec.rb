# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboxPolicy, type: :policy do
  subject(:inbox_policy) { described_class }

  let(:account) { create(:account) }

  let(:administrator) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:administrator_context) { { user: administrator, account: account, account_user: account.account_users.first } }
  let(:agent_context) { { user: agent, account: account, account_user: account.account_users.first } }

  permissions :create?, :destroy?, :update?, :refresh_whatsapp_web_qr?, :reconnect_whatsapp_web?,
              :disconnect_whatsapp_web?, :repair_whatsapp_web?, :whatsapp_web_diagnostics? do
    context 'when administrator' do
      it { expect(inbox_policy).to permit(administrator_context, inbox) }
    end

    context 'when agent' do
      it { expect(inbox_policy).not_to permit(agent_context, inbox) }
    end
  end

  permissions :index? do
    context 'when administrator' do
      it { expect(inbox_policy).to permit(administrator_context, inbox) }
    end

    context 'when agent' do
      it { expect(inbox_policy).to permit(agent_context, inbox) }
    end
  end

  permissions :show? do
    before do
      Current.user = agent
      Current.account = account
    end

    after { Current.reset }

    it 'allows an agent assigned to the inbox' do
      create(:inbox_member, inbox: inbox, user: agent)

      expect(inbox_policy).to permit(agent_context, inbox)
    end

    it 'allows an account agent to access a messaging inbox without membership' do
      expect(inbox_policy).to permit(agent_context, inbox)
    end

    it 'requires membership for a Voice inbox' do
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox

      expect(inbox_policy).not_to permit(agent_context, voice_inbox)

      create(:inbox_member, inbox: voice_inbox, user: agent)

      expect(inbox_policy).to permit(agent_context, voice_inbox)
    end

    it 'denies an inbox from another account' do
      expect(inbox_policy).not_to permit(agent_context, create(:inbox, account: create(:account)))
    end
  end

  describe described_class::Scope do
    it 'returns every messaging inbox but only assigned Voice inboxes' do
      other_inbox = create(:inbox, account: account)
      voice_inbox = create(:channel_voice, :sipuni, account: account).inbox
      create(:inbox, account: create(:account))

      result = described_class.new(agent_context, Inbox.all).resolve

      expect(result).to contain_exactly(inbox, other_inbox)

      create(:inbox_member, inbox: voice_inbox, user: agent)
      assigned_result = described_class.new(agent_context, Inbox.all).resolve

      expect(assigned_result).to contain_exactly(inbox, other_inbox, voice_inbox)
    end
  end
end
