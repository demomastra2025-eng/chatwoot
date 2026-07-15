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
    def browser_registration_context(profile, suffix: 'current')
      {
        registration_config_version: profile.registration_config_version,
        registration_instance_id: "registration-#{suffix}",
        janus_session_id: "janus-session-#{suffix}",
        janus_handle_id: "janus-handle-#{suffix}"
      }
    end

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
        registration_context: browser_registration_context(profile).merge(registration_config_version: nil)
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

        profile.update_browser_registration!(
          registered: true,
          registration_context: browser_registration_context(profile)
        )
        expect(profile.reload.browser_registered?).to be(true)
        expect(profile.registered_for_routing?).to be(true)

        travel 120.seconds
        expect(profile.reload.browser_registered?).to be(true)
        expect(profile.registered_for_routing?).to be(true)

        travel 1.second
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

      profile.update_browser_registration!(
        registered: true,
        registration_context: browser_registration_context(profile)
      )
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
      context = browser_registration_context(profile)
      profile.update_browser_registration!(registered: true, registration_context: context)

      expect(profile.browser_registration_context_matches?(context)).to be(true)
      expect(profile.browser_registration_context_matches?(context.merge(registration_instance_id: 'stale-janus-registration'))).to be(false)
    end

    it 'atomically fences a competing fresh browser registration lease' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      stale_copy = described_class.find(profile.id)
      current_context = browser_registration_context(profile, suffix: 'current')
      competing_context = browser_registration_context(profile, suffix: 'competing')

      expect(profile.update_browser_registration!(registered: true, registration_context: current_context)).to eq(:updated)
      expect(stale_copy.update_browser_registration!(registered: true, registration_context: competing_context)).to eq(:conflict)
      expect(profile.reload.metadata.dig('registration_context', 'registration_instance_id')).to eq('registration-current')
    end

    it 'allows a new browser lease after the previous lease expires' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        current_context = browser_registration_context(profile, suffix: 'current')
        replacement_context = browser_registration_context(profile, suffix: 'replacement')

        profile.update_browser_registration!(registered: true, registration_context: current_context)
        travel 3.minutes

        expect(profile.update_browser_registration!(registered: true, registration_context: replacement_context)).to eq(:updated)
        expect(profile.reload.metadata.dig('registration_context', 'registration_instance_id')).to eq('registration-replacement')
      end
    end

    it 'does not let a delayed online heartbeat revive a newer offline event' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      context = browser_registration_context(profile).merge(
        presence_sequence: 1
      )

      expect(
        profile.update_browser_registration!(
          registered: true,
          registration_context: context
        )
      ).to eq(:updated)
      expect(
        profile.update_browser_registration!(
          registered: false,
          registration_context: context.merge(presence_sequence: 3)
        )
      ).to eq(:updated)
      expect(
        profile.update_browser_registration!(
          registered: true,
          registration_context: context.merge(presence_sequence: 2)
        )
      ).to eq(:stale)

      expect(profile.reload.registered_for_routing?).to be(false)
      expect(profile.metadata).to include(
        'last_registration_instance_id' => context[:registration_instance_id],
        'last_presence_sequence' => 3
      )
    end
  end
end
