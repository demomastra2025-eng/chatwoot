require 'rails_helper'

RSpec.describe Telephony::ReconcileCallSessionsJob do
  it 'runs telephony call reconciliation' do
    service = instance_double(Telephony::CallReconciliationService, perform: { checked: 0, updated: 0, missing: 0, errors: 0 })
    allow(Telephony::CallReconciliationService).to receive(:new).and_return(service)

    described_class.perform_now

    expect(Telephony::CallReconciliationService).to have_received(:new)
    expect(service).to have_received(:perform)
  end
end
