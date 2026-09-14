# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactPolicy, type: :policy do
  subject(:contact_policy) { described_class }

  let(:account) { create(:account) }

  let(:administrator) { create(:user, :administrator, account: account) }
  let(:agent) { create(:user, account: account) }
  let(:contact) { create(:contact) }

  let(:administrator_context) { { user: administrator, account: account, account_user: account.account_users.first } }
  let(:agent_context) { { user: agent, account: account, account_user: account.account_users.first } }

  permissions :index?, :show?, :update? do
    context 'when administrator' do
      it { expect(contact_policy).to permit(administrator_context, contact) }
    end

    context 'when agent' do
      it { expect(contact_policy).to permit(agent_context, contact) }
    end
  end

  permissions :create? do
    context 'when administrator' do
      it { expect(contact_policy).to permit(administrator_context, contact) }
    end

    context 'when agent' do
      it { expect(contact_policy).to permit(agent_context, contact) }
    end
  end

  context 'when AccessRole is enforced and the agent participates in the contact thread' do
    let(:account) do
      create(:account).tap do |record|
        record.enable_features!('communication_threads')
        AccessControl::SystemRoleBootstrapper.call(account: record)
      end
    end
    let(:contact) { create(:contact, account: account, contact_type: :customer) }
    let(:conversation) { create(:conversation, account: account, contact: contact) }

    before do
      CommunicationThreadParticipant.create!(
        account: account,
        communication_thread: conversation.reload.communication_thread,
        user: agent
      )
      AccessControl::ModeTransition.call(account: account, to: :shadow)
      AccessControl::ModeTransition.call(account: account, to: :enforced)
    end

    it 'allows viewing and listing the contact without granting edit access' do
      policy = described_class.new(agent_context, contact)

      expect(policy).to be_index
      expect(policy).to be_show
      expect(policy).not_to be_update
      expect(described_class::Scope.new(agent_context, Contact.all).resolve).to include(contact)
    end
  end
end
