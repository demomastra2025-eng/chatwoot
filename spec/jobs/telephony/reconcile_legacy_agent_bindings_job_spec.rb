# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::ReconcileLegacyAgentBindingsJob do
  let(:service) { instance_double(Telephony::LegacyAgentBindingReconciliationService, perform: { checked: 0 }) }

  before do
    allow(Telephony::LegacyAgentBindingReconciliationService).to receive(:new).and_return(service)
  end

  it 'reconciles all accounts when scheduled without an account id' do
    described_class.perform_now

    expect(Telephony::LegacyAgentBindingReconciliationService).to have_received(:new).with(no_args)
    expect(service).to have_received(:perform)
  end

  it 'reconciles only the requested account when account id is present' do
    account = create(:account)

    described_class.perform_now(account.id)

    expect(Telephony::LegacyAgentBindingReconciliationService).to have_received(:new).with(account: account)
    expect(service).to have_received(:perform)
  end

  it 'does not fall back to all accounts when requested account id is missing' do
    result = described_class.perform_now(-1)

    expect(Telephony::LegacyAgentBindingReconciliationService).not_to have_received(:new)
    expect(result).to include(
      checked: 0,
      disabled: 0,
      skipped: 0,
      skipped_reason: 'account_not_found'
    )
  end
end
