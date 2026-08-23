require 'rails_helper'

RSpec.describe Whatsapp::PendingMessageMutation do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  it 'accepts an account-scoped pending mutation' do
    mutation = described_class.new(
      account: account,
      inbox: inbox,
      event_id: 'wamid.event-1',
      target_source_id: 'wamid.target-1',
      mutation_type: 'edit'
    )

    expect(mutation).to be_valid
  end

  it 'rejects an inbox from another account' do
    mutation = described_class.new(
      account: account,
      inbox: create(:inbox),
      event_id: 'wamid.event-1',
      target_source_id: 'wamid.target-1',
      mutation_type: 'edit'
    )

    expect(mutation).not_to be_valid
    expect(mutation.errors[:inbox]).to include('must belong to the same account')
  end
end
