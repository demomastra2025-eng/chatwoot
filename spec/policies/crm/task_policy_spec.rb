# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::TaskPolicy, type: :policy do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:administrator) { create(:user, :administrator, account: account) }
  let(:task) { create(:crm_task, account: account) }

  let(:agent_context) { { user: agent, account: account, account_user: agent.account_users.find_by!(account: account) } }
  let(:administrator_context) { { user: administrator, account: account, account_user: administrator.account_users.find_by!(account: account) } }

  it 'allows plain agents to use task runtime actions' do
    policy = described_class.new(agent_context, task)

    aggregate_failures do
      expect(policy.index?).to be(true)
      expect(policy.show?).to be(true)
      expect(policy.timeline?).to be(true)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.change_status?).to be(true)
      expect(policy.archive?).to be(true)
      expect(policy.unarchive?).to be(true)
    end
  end

  it 'allows administrators to use task runtime actions' do
    policy = described_class.new(administrator_context, task)

    aggregate_failures do
      expect(policy.index?).to be(true)
      expect(policy.show?).to be(true)
      expect(policy.timeline?).to be(true)
      expect(policy.create?).to be(true)
      expect(policy.update?).to be(true)
      expect(policy.change_status?).to be(true)
      expect(policy.archive?).to be(true)
      expect(policy.unarchive?).to be(true)
    end
  end
end
