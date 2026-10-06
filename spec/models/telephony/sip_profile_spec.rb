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

  describe '#registration_context_matches?' do
    let(:profile) do
      create(
        :telephony_sip_profile,
        availability_mode: 'browser_webphone',
        sip_username: '1003',
        sip_host: 'VPBX-COMPANY-TEST.CLOUDPBX.BEELINE.KZ',
        agent_aor: 'sip:1003@VPBX-COMPANY-TEST.CLOUDPBX.BEELINE.KZ'
      )
    end

    it 'compares the SIP host case-insensitively like SIP does' do
      context = profile.registration_context_payload.merge('sip_host' => 'VPBX-COMPANY-TEST.CLOUDPBX.BEELINE.KZ')

      expect(profile.sip_host).to eq('vpbx-company-test.cloudpbx.beeline.kz')
      expect(profile.registration_context_matches?(context)).to be(true)
      expect(profile.registration_context_matches?(context.merge('sip_host' => ' Vpbx-Company-Test.cloudpbx.beeline.kz '))).to be(true)
    end

    it 'still rejects another SIP host, user or config version' do
      context = profile.registration_context_payload

      expect(profile.registration_context_matches?(context.merge('sip_host' => 'vpbx-company-other.cloudpbx.beeline.kz'))).to be(false)
      expect(profile.registration_context_matches?(context.merge('sip_username' => '1004'))).to be(false)
      expect(profile.registration_context_matches?(context.merge('registration_config_version' => 'old-version'))).to be(false)
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

    def leased_browser_registration_context(profile, suffix: 'current')
      lease = profile.acquire_browser_registration_lease!(
        client_instance_id: "tab-#{suffix}",
        user_id: profile.user_id
      )
      browser_registration_context(profile, suffix: suffix).merge(
        registration_instance_id: lease.fetch(:registration_instance_id)
      )
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

        registration_context = leased_browser_registration_context(profile)
        profile.update_browser_registration!(
          registered: true,
          registration_context: registration_context
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

      registration_context = leased_browser_registration_context(profile)
      profile.update_browser_registration!(
        registered: true,
        registration_context: registration_context
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
      context = leased_browser_registration_context(profile)
      profile.update_browser_registration!(registered: true, registration_context: context)

      expect(profile.browser_registration_context_matches?(context)).to be(true)
      expect(profile.browser_registration_context_matches?(context.merge(registration_instance_id: 'stale-janus-registration'))).to be(false)
    end

    it 'atomically fences a competing fresh browser registration lease' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      stale_copy = described_class.find(profile.id)
      current_context = leased_browser_registration_context(profile, suffix: 'current')
      competing_context = browser_registration_context(profile, suffix: 'competing')

      expect(profile.update_browser_registration!(registered: true, registration_context: current_context)).to eq(:updated)
      expect(stale_copy.update_browser_registration!(registered: true, registration_context: competing_context)).to eq(:conflict)
      expect(profile.reload.metadata.dig('registration_context', 'registration_instance_id')).to eq(
        current_context[:registration_instance_id]
      )
    end

    it 'allows a new browser lease after the previous lease expires' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        current_context = leased_browser_registration_context(profile, suffix: 'current')

        profile.update_browser_registration!(registered: true, registration_context: current_context)
        travel 3.minutes

        replacement_context = leased_browser_registration_context(profile, suffix: 'replacement')

        expect(profile.update_browser_registration!(registered: true, registration_context: replacement_context)).to eq(:updated)
        expect(profile.reload.metadata.dig('registration_context', 'registration_instance_id')).to eq(
          replacement_context[:registration_instance_id]
        )
      end
    end

    it 'acquires a bootstrap lease for one browser tab before Janus registration' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')

        owner = profile.acquire_browser_registration_lease!(client_instance_id: 'tab-owner', user_id: profile.user_id)
        competing = described_class.find(profile.id).acquire_browser_registration_lease!(
          client_instance_id: 'tab-competing',
          user_id: profile.user_id
        )
        renewed = profile.acquire_browser_registration_lease!(client_instance_id: 'tab-owner', user_id: profile.user_id)

        expect(owner).to include(acquired: true, registration_instance_id: be_present)
        expect(competing).to include(acquired: false, registration_instance_id: owner[:registration_instance_id])
        expect(renewed).to include(acquired: true, registration_instance_id: owner[:registration_instance_id])
      end
    end

    it 'hands the lease to another tab of the same browser without waiting for expiry' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        owner = profile.acquire_browser_registration_lease!(
          client_instance_id: 'tab-owner', browser_instance_id: 'browser-1', user_id: profile.user_id
        )
        owner_context = browser_registration_context(profile).merge(registration_instance_id: owner[:registration_instance_id])
        expect(profile.update_browser_registration!(registered: true, registration_context: owner_context)).to eq(:updated)

        successor = described_class.find(profile.id).acquire_browser_registration_lease!(
          client_instance_id: 'tab-reloaded', browser_instance_id: 'browser-1', user_id: profile.user_id
        )
        successor_context = browser_registration_context(profile, suffix: 'reloaded').merge(
          registration_instance_id: successor[:registration_instance_id]
        )

        expect(successor).to include(acquired: true)
        expect(successor[:registration_instance_id]).not_to eq(owner[:registration_instance_id])
        expect(profile.reload).not_to be_registered_for_routing
        expect(profile.update_browser_registration!(registered: true, registration_context: owner_context)).to eq(:conflict)
        expect(profile.update_browser_registration!(registered: true, registration_context: successor_context)).to eq(:updated)
        expect(profile.reload).to be_registered_for_routing
      end
    end

    it 'keeps the lease with its owner when another browser asks for it' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        owner = profile.acquire_browser_registration_lease!(
          client_instance_id: 'tab-owner', browser_instance_id: 'browser-1', user_id: profile.user_id
        )

        competing = described_class.find(profile.id).acquire_browser_registration_lease!(
          client_instance_id: 'tab-other', browser_instance_id: 'browser-2', user_id: profile.user_id
        )

        expect(competing).to include(acquired: false, registration_instance_id: owner[:registration_instance_id])
      end
    end

    it 'does not acquire a browser registration lease without a client instance' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')

      expect(profile.acquire_browser_registration_lease!(client_instance_id: nil, user_id: profile.user_id)).to eq(
        acquired: false,
        registration_instance_id: nil
      )
    end

    it 'rejects browser registration without an active lease' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')

      expect(
        profile.update_browser_registration!(
          registered: true,
          registration_context: browser_registration_context(profile)
        )
      ).to eq(:conflict)
      expect(profile.reload).not_to be_registered_for_routing
    end

    it 'fences presence to the token lease and releases it on matching unregister' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      lease = profile.acquire_browser_registration_lease!(client_instance_id: 'tab-owner', user_id: profile.user_id)
      owner_context = browser_registration_context(profile).merge(registration_instance_id: lease[:registration_instance_id])
      competing_context = browser_registration_context(profile, suffix: 'competing')

      expect(profile.update_browser_registration!(registered: true, registration_context: competing_context)).to eq(:conflict)
      expect(profile.update_browser_registration!(registered: true, registration_context: owner_context)).to eq(:updated)
      expect(profile.update_browser_registration!(registered: false, registration_context: owner_context)).to eq(:updated)
      expect(profile.reload.metadata).not_to have_key('browser_registration_lease')
    end

    it 'does not let an expired browser registration lease revive routing' do
      freeze_time do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        lease = profile.acquire_browser_registration_lease!(client_instance_id: 'expired-tab', user_id: profile.user_id)
        registration_context = browser_registration_context(profile).merge(
          registration_instance_id: lease[:registration_instance_id]
        )
        original_expiry = lease[:expires_at]

        travel Telephony::SipProfile::DEFAULT_REGISTRATION_TTL + 1.second

        expect(profile.update_browser_registration!(registered: true, registration_context: registration_context)).to eq(:conflict)
        expect(profile.reload.metadata.dig('browser_registration_lease', 'expires_at')).to eq(original_expiry)
        expect(profile).not_to be_registered_for_routing
      end
    end

    it 'does not let a delayed online heartbeat revive a newer offline event' do
      profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
      context = leased_browser_registration_context(profile).merge(
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

  describe 'a browser phone that follows its user' do
    def register_browser_phone(profile, browser_instance_id: 'browser-1')
      lease = profile.acquire_browser_registration_lease!(
        client_instance_id: "tab-#{profile.id}", browser_instance_id: browser_instance_id, user_id: profile.user_id
      )
      context = {
        registration_config_version: profile.registration_config_version,
        registration_instance_id: lease.fetch(:registration_instance_id),
        janus_session_id: "janus-session-#{profile.id}",
        janus_handle_id: "janus-handle-#{profile.id}"
      }
      profile.update_browser_registration!(registered: true, registration_context: context)
      context
    end

    def acquire_for_user(profile, browser_instance_id:, client_instance_id: "tab-new-#{profile.id}")
      profile.acquire_browser_registration_lease!(
        client_instance_id: client_instance_id, browser_instance_id: browser_instance_id, user_id: profile.user_id
      )
    end

    describe 'exposed registration state' do
      it 'reports a browser phone with fresh heartbeats as registered' do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        register_browser_phone(profile)

        payload = profile.reload.to_telephony_h

        expect(payload).to include(registered_for_routing: true, registration_state: 'registered')
        expect(payload[:metadata]).to include('presence' => 'online', 'registered' => true)
      end

      it 'reports offline once the heartbeats stopped, while the stored flags stay as they were' do
        freeze_time do
          profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
          register_browser_phone(profile)
          travel 3.minutes

          payload = profile.reload.to_telephony_h

          expect(payload).to include(registered_for_routing: false, registration_state: 'offline')
          expect(payload[:metadata]).to include(
            'registration_state' => 'offline', 'presence' => 'offline', 'registered' => false, 'available' => false
          )
          expect(profile.metadata).to include('registration_state' => 'registered', 'presence' => 'online', 'registered' => true)
        end
      end

      it 'keeps the provider reported state of a profile that is not a browser phone' do
        profile = create(:telephony_sip_profile, availability_mode: 'external_extension')
        profile.update_columns(metadata: { 'registration_state' => 'registered', 'last_presence_event_at' => 1.day.ago.iso8601 })

        expect(profile.reload.to_telephony_h).to include(registration_state: 'registered')
      end

      it 'does not invent a state for a browser phone that never reported one' do
        profile = create(:telephony_sip_profile, availability_mode: 'browser_webphone')
        profile.update_columns(metadata: {})

        expect(profile.reload.to_telephony_h).not_to have_key(:registration_state)
      end
    end

    describe 'one browser serves one signed-in user' do
      let(:asel) { create(:telephony_sip_profile, availability_mode: 'browser_webphone') }
      let(:marina) { create(:telephony_sip_profile, availability_mode: 'browser_webphone') }

      it 'releases the phone of the previous user as soon as another user registers in the same browser' do
        register_browser_phone(asel)
        expect(asel.reload).to be_registered_for_routing

        result = acquire_for_user(marina, browser_instance_id: 'browser-1')

        expect(result).to include(acquired: true)
        asel.reload
        expect(asel).not_to be_registered_for_routing
        expect(asel.metadata).to include('registration_state' => 'offline', 'presence' => 'offline', 'registered' => false)
        expect(asel.metadata).not_to have_key('browser_registration_lease')
        expect(asel.metadata['last_browser_release']).to include(
          'reason' => 'browser_taken_over_by_other_user', 'by_user_id' => marina.user_id,
          'client_instance_id' => "tab-#{asel.id}", 'browser_instance_id' => 'browser-1'
        )
      end

      it 'does not let the released phone come back with a late heartbeat' do
        asel_context = register_browser_phone(asel)
        acquire_for_user(marina, browser_instance_id: 'browser-1')

        expect(asel.reload.update_browser_registration!(registered: true, registration_context: asel_context)).to eq(:conflict)
        expect(asel.reload).not_to be_registered_for_routing
      end

      it 'keeps a displaced old tab in standby after its conflicting heartbeat' do
        asel_context = register_browser_phone(asel)
        expect(acquire_for_user(marina, browser_instance_id: 'browser-1')).to include(acquired: true)

        2.times do
          expect(asel.reload.update_browser_registration!(registered: true, registration_context: asel_context)).to eq(:conflict)
          expect(acquire_for_user(asel, browser_instance_id: 'browser-1', client_instance_id: "tab-#{asel.id}"))
            .to include(acquired: false)
          expect(asel.reload).not_to be_registered_for_routing
          expect(marina.reload.metadata).to have_key('browser_registration_lease')
        end
      end

      it 'holds the browser lock through the release scan' do
        lock_held_during_release = false
        allow(marina).to receive(:release_other_users_in_browser!).and_wrap_original do |release, *args|
          lock_held_during_release = described_class.connection.select_value(
            "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
          ).to_i.positive?
          release.call(*args)
        end

        expect(acquire_for_user(marina, browser_instance_id: 'browser-1')).to include(acquired: true)
        expect(lock_held_during_release).to be(true)
      end

      it 'accepts a new page load for the previous user' do
        register_browser_phone(asel)
        expect(acquire_for_user(marina, browser_instance_id: 'browser-1')).to include(acquired: true)

        result = acquire_for_user(asel, browser_instance_id: 'browser-1', client_instance_id: 'tab-new-page')

        expect(result).to include(acquired: true)
        expect(marina.reload.metadata).not_to have_key('browser_registration_lease')
      end

      it 'lets the displaced tab acquire once the other user no longer holds the browser' do
        register_browser_phone(asel)
        acquire_for_user(marina, browser_instance_id: 'browser-1')
        marina.update!(metadata: {})

        result = acquire_for_user(asel, browser_instance_id: 'browser-1', client_instance_id: "tab-#{asel.id}")

        expect(result).to include(acquired: true)
      end

      it 'leaves the other profiles of the user who signs in alone' do
        marina_second_line = create(
          :telephony_sip_profile, availability_mode: 'browser_webphone', account: marina.account, user: marina.user
        )
        register_browser_phone(marina_second_line)

        acquire_for_user(marina, browser_instance_id: 'browser-1')

        expect(marina_second_line.reload).to be_registered_for_routing
        expect(marina.reload.metadata).to have_key('browser_registration_lease')
      end

      it 'leaves a phone registered from another browser alone' do
        register_browser_phone(asel, browser_instance_id: 'browser-1')

        acquire_for_user(marina, browser_instance_id: 'browser-2')

        expect(asel.reload).to be_registered_for_routing
      end

      it 'does not release anything when the new user does not get the lease' do
        register_browser_phone(asel, browser_instance_id: 'browser-1')
        marina.acquire_browser_registration_lease!(client_instance_id: 'tab-home', browser_instance_id: 'browser-3', user_id: marina.user_id)

        result = acquire_for_user(marina, browser_instance_id: 'browser-1', client_instance_id: 'tab-office')

        expect(result).to include(acquired: false)
        expect(asel.reload).to be_registered_for_routing
      end

      it 'does not cut the phone of a user who is on a call' do
        register_browser_phone(asel, browser_instance_id: 'browser-1')
        create(
          :telephony_call_session,
          account: asel.account,
          status: 'in_progress',
          metadata: { 'operator_claim' => { 'user_id' => asel.user_id, 'sip_profile_id' => asel.id } }
        )

        result = acquire_for_user(marina, browser_instance_id: 'browser-1')

        expect(result).to include(acquired: true)
        expect(asel.reload).to be_registered_for_routing
        expect(asel.metadata).to have_key('browser_registration_lease')
      end

      it 'releases the phone at the next acquisition once the call has ended' do
        register_browser_phone(asel, browser_instance_id: 'browser-1')
        call_session = create(
          :telephony_call_session,
          account: asel.account,
          status: 'in_progress',
          metadata: { 'operator_claim' => { 'user_id' => asel.user_id, 'sip_profile_id' => asel.id } }
        )
        acquire_for_user(marina, browser_instance_id: 'browser-1')
        call_session.update!(status: 'completed')

        acquire_for_user(marina, browser_instance_id: 'browser-1')

        expect(asel.reload).not_to be_registered_for_routing
        expect(asel.metadata).not_to have_key('browser_registration_lease')
      end

      it 'does nothing for a request that carries no browser identity' do
        register_browser_phone(asel, browser_instance_id: 'browser-1')

        acquire_for_user(marina, browser_instance_id: nil)

        expect(asel.reload).to be_registered_for_routing
      end

      it 'does not touch the phone of the same user in another tab of the browser' do
        register_browser_phone(asel, browser_instance_id: 'browser-1')

        result = acquire_for_user(asel, browser_instance_id: 'browser-1', client_instance_id: 'tab-second')

        expect(result).to include(acquired: true)
        expect(asel.reload.metadata).not_to have_key('last_browser_release')
      end
    end
  end
end
