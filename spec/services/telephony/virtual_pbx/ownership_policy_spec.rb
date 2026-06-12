require 'rails_helper'

RSpec.describe Telephony::VirtualPbx::OwnershipPolicy do
  let(:account) { create(:account) }
  let(:policy) { described_class.new(account: account) }

  it 'allows owned OneLink resources to be mutated' do
    state = { ownership: { managed_by: 'onelink', read_only: false } }

    decision = policy.check!(operation: 'update', desired_state: state)

    expect(decision).to include(allowed: true, risk: 'safe')
  end

  it 'blocks legacy resources until explicit migration/adoption' do
    state = { ownership: { managed_by: nil, read_only: true, ownership_status: 'legacy_reference' } }

    decision = policy.check!(operation: 'update', desired_state: state)

    expect(decision).to include(allowed: false, risk: 'blocked')
    expect(decision[:conflict]).to include('legacy')
  end

  it 'unlinks shared trunks or credentials instead of deleting them' do
    provider_connection = create(:telephony_provider_connection, account: account)
    create(:telephony_number_binding, account: account, provider_connection: provider_connection)
    create(:telephony_number_binding, account: account, provider_connection: provider_connection)

    decision = policy.delete_strategy(provider_connection: provider_connection)

    expect(decision).to include(delete_provider_connection: false, unlink_provider_connection: true)
  end
end
