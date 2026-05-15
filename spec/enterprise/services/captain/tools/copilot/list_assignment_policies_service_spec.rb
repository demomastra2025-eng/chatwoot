require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::ListAssignmentPoliciesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  it 'returns account-scoped assignment policies with attached inbox IDs' do
    inbox = create(:inbox, account: account, name: 'Support')
    policy = create(:assignment_policy, account: account, name: 'Support routing', assignment_order: 'balanced')
    create(:inbox_assignment_policy, inbox: inbox, assignment_policy: policy)
    create(:assignment_policy, account: create(:account), name: 'Other account')

    payload = JSON.parse(service.execute(query: 'support', enabled: true, limit: 10))

    expect(payload['total_count']).to eq(1)
    expect(payload['assignment_orders']).to include('round_robin')
    expect(payload['conversation_priorities']).to include('earliest_created')
    expect(payload['policies'].size).to eq(1)
    expect(payload['policies'].first).to include(
      'id' => policy.id,
      'name' => 'Support routing',
      'enabled' => true,
      'assignment_order' => 'balanced',
      'inbox_ids' => [inbox.id]
    )
  end

  it 'is active only for account administrators' do
    agent = create(:user, account: account)

    expect(service).to be_active
    expect(described_class.new(assistant, user: agent)).not_to be_active
  end
end
