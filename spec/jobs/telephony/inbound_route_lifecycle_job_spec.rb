require 'rails_helper'

RSpec.describe Telephony::InboundRouteLifecycleJob do
  it 'discards permanent invalid lifecycle events instead of retrying them into DeadSet' do
    payload = {
      'event_key' => 'evt-missing-account',
      'account_id' => '999999999',
      'call_ref' => 'call-missing-account',
      'event' => 'answered'
    }

    expect { described_class.perform_now(payload) }.not_to raise_error
  end
end
