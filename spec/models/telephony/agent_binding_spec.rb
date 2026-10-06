require 'rails_helper'

RSpec.describe Telephony::AgentBinding do
  describe '#registered_for_routing?' do
    it 'keeps a browser webphone routable through a short service restart window' do
      freeze_time do
        binding = create(:telephony_agent_binding, :registered)

        travel 4.minutes
        expect(binding.reload.registered_for_routing?).to be(true)

        travel 2.minutes
        expect(binding.reload.registered_for_routing?).to be(false)
      end
    end
  end

  describe '#to_telephony_h' do
    it 'reports a browser registration without fresh heartbeats as offline' do
      freeze_time do
        binding = create(:telephony_agent_binding, :registered)
        expect(binding.to_telephony_h).to include(registered_for_routing: true, registration_state: 'registered')

        travel 6.minutes
        stale = binding.reload.to_telephony_h

        expect(stale).to include(registered_for_routing: false, registration_state: 'offline')
        expect(binding.metadata).to include('registration_state' => 'registered', 'presence' => 'online')
      end
    end
  end
end
