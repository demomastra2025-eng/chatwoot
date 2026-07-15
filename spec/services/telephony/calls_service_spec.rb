require 'rails_helper'

RSpec.describe Telephony::CallsService do
  describe '#create_outbound!' do
    it 'checks operator availability before creating provider side effects' do
      account = create(:account)
      user = create(:user, account: account, role: :agent)
      contact = instance_double(Contact, phone_number: '+77070001002')
      inbox = instance_double(Inbox)
      conversation = instance_double(Conversation)
      guard = instance_double(Telephony::OperatorBusyService)

      allow(Telephony::OperatorBusyService).to receive(:new)
        .with(account: account, user: user)
        .and_return(guard)
      allow(guard).to receive(:with_lock).and_raise(
        Telephony::Error.new(
          code: 'OPERATOR_BUSY',
          message: 'Operator already has an active call',
          status: :conflict
        )
      )

      expect do
        described_class.new(account: account).create_outbound!(
          inbox: inbox,
          conversation: conversation,
          contact: contact,
          user: user
        )
      end.to raise_error(Telephony::Error) { |error| expect(error.code).to eq('OPERATOR_BUSY') }
    end
  end
end
