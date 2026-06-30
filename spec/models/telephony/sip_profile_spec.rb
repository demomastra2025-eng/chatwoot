require 'rails_helper'

RSpec.describe Telephony::SipProfile do
  describe 'validations' do
    it 'does not allow duplicate internal extensions inside the same inbox' do
      account = create(:account)
      inbox = create(:inbox, account: account)
      first_user = create(:user, account: account, role: :agent)
      second_user = create(:user, account: account, role: :agent)
      create(:telephony_sip_profile, account: account, inbox: inbox, user: first_user, internal_extension: '505')

      duplicate = build(:telephony_sip_profile, account: account, inbox: inbox, user: second_user, internal_extension: '505')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:internal_extension]).to be_present
    end

    it 'allows the same internal extension in another inbox for the same account' do
      account = create(:account)
      first_inbox = create(:inbox, account: account)
      second_inbox = create(:inbox, account: account)
      create(:telephony_sip_profile, account: account, inbox: first_inbox, internal_extension: '505', agent_aor: 'sip:first-505@example.test')

      profile = build(
        :telephony_sip_profile,
        account: account,
        inbox: second_inbox,
        internal_extension: '505',
        agent_aor: 'sip:second-505@example.test'
      )

      expect(profile).to be_valid
    end
  end

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
