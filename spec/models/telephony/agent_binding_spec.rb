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
end
