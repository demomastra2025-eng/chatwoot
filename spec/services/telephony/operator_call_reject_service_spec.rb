# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::OperatorCallRejectService do
  subject(:service) do
    described_class.new(
      account: instance_double(Account),
      user: instance_double(User),
      call_ref: external_call_ref
    )
  end

  let(:external_call_ref) { 'wazo:janus:87:provider-call-id' }

  before do
    call_session = instance_double(Telephony::CallSession, external_call_ref: external_call_ref)
    service.instance_variable_set(:@call_session, call_session)
  end

  it 'classifies Wazo browser calls as native Janus SIP references' do
    expect(service.send(:janus_sip_call_ref?)).to be(true)
  end
end
