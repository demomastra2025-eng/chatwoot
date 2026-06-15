require 'rails_helper'

RSpec.describe Telephony::SipProfile do
  describe '#registered_for_routing?' do
    it 'keeps external extensions routable without browser registration' do
      profile = create(:telephony_sip_profile, availability_mode: 'external_extension')

      expect(profile.registered_for_routing?).to be(true)
    end

    it 'does not route browser webphone profiles before a fresh scoped heartbeat' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone', status: 'active')

      expect(profile.browser_registered?).to be(false)
      expect(profile.registered_for_routing?).to be(false)
    end

    it 'routes browser webphone profiles only while browser registration is fresh' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone', status: 'active')

        expect(profile.browser_registered?).to be(false)

        profile.update_browser_registration!(registered: true)
        expect(profile.reload.browser_registered?).to be(true)
        expect(profile.registered_for_routing?).to be(true)

        travel 6.minutes
        expect(profile.reload.browser_registered?).to be(false)
        expect(profile.registered_for_routing?).to be(false)
      end
    end
  end
end
