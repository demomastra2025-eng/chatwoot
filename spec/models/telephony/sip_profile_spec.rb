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

    it 'requires a user for human operator profiles' do
      account = create(:account)
      inbox = create(:inbox, account: account)
      profile = build(:telephony_sip_profile, account: account, inbox: inbox, user: nil, sip_username: 'operator-without-user')

      expect(profile).not_to be_valid
      expect(profile.errors[:user]).to be_present
    end

    it 'allows one voice agent profile without a user per inbox' do
      account = create(:account)
      inbox = create(:inbox, account: account)
      create(:telephony_sip_profile, :voice_agent, account: account, inbox: inbox)

      duplicate = build(:telephony_sip_profile, :voice_agent, account: account, inbox: inbox, internal_extension: '9099')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:profile_kind]).to be_present
    end
  end

  describe '#registered_for_routing?' do
    it 'lazily assigns a registration config version to legacy profiles' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      profile.update_column(:metadata, profile.metadata.except('registration_config_version'))

      expect { profile.ensure_registration_config_version! }
        .to change { profile.reload.registration_config_version }
        .from(nil)
      expect(profile.registration_config_version).to be_present
    end

    it 'keeps a live legacy registration routable until its next token bootstrap' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      profile.update_column(
        :metadata,
        profile.metadata.except(
          'registration_config_version',
          'registration_context_signature',
          'registration_context'
        ).merge(
          'registered' => true,
          'registration_state' => 'registered',
          'last_presence_event_at' => Time.current.iso8601,
          'last_registered_event_at' => Time.current.iso8601
        )
      )

      expect(profile.reload.registered_for_routing?).to be(true)

      profile.update_browser_registration!(
        registered: true,
        registration_context: { registration_config_version: nil }
      )

      expect(profile.reload.registration_config_version).to be_nil
      expect(profile.registered_for_routing?).to be(true)

      profile.ensure_registration_config_version!

      expect(profile.reload.registration_config_version).to be_present
      expect(profile.registered_for_routing?).to be(false)
    end

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

    it 'invalidates browser registration when route-critical SIP profile fields change' do
      profile = create(
        :telephony_sip_profile,
        availability_mode: 'browser_webphone',
        status: 'active',
        sip_username: 'old-login',
        sip_host: 'ats01.kz.sipuni.com',
        agent_aor: 'sip:old-login@ats01.kz.sipuni.com'
      )
      old_version = profile.registration_config_version

      profile.update_browser_registration!(registered: true)
      expect(profile.reload.registered_for_routing?).to be(true)

      profile.update!(sip_username: 'new-login', agent_aor: 'sip:new-login@ats01.kz.sipuni.com')

      expect(profile.reload.registered_for_routing?).to be(false)
      expect(profile.registration_config_version).not_to eq(old_version)
      expect(profile.metadata).to include(
        'registration_state' => 'offline',
        'registered' => false
      )
    end

    it 'matches unregister events to the active Janus registration instance' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      context = {
        registration_config_version: profile.registration_config_version,
        registration_instance_id: 'current-janus-registration'
      }
      profile.update_browser_registration!(registered: true, registration_context: context)

      expect(profile.browser_registration_context_matches?(context)).to be(true)
      expect(profile.browser_registration_context_matches?(context.merge(registration_instance_id: 'stale-janus-registration'))).to be(false)
    end
  end
end
