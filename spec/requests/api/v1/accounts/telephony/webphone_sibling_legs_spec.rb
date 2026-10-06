require 'rails_helper'

# Every operator browser registered on a Beeline channel receives its own INVITE
# for one external call and reports it as a leg of its own. The legs of one
# physical call must form one logical call.
RSpec.describe 'Telephony Webphone incoming legs of one Beeline call', type: :request do
  include_context 'with three Beeline operator browsers'

  describe 'one physical call reported by three operator browsers' do
    before do
      profiles.each_with_index { |profile, index| report_leg(profile, "sip-call-id-#{index}") }
    end

    it 'answers every browser' do
      expect(response).to have_http_status(:ok)
      expect(account.telephony_call_sessions.count).to eq(3)
    end

    it 'puts the legs into one logical call' do
      sessions = profiles.each_with_index.map { |profile, index| leg_session(profile, "sip-call-id-#{index}") }

      expect(sessions.map { |session| logical_key(session) }.uniq.size).to eq(1)
      expect(logical_key(sessions.first)).to be_present
      expect(sessions.map { |session| session.metadata.dig('metadata', 'logical_call_group_ref') }.uniq).to eq([sessions.first.external_call_ref])
      expect(sessions.first.logical_group_sessions).to match_array(sessions)
    end

    it 'sends each operator the shared key for his own leg only' do
      sessions = profiles.each_with_index.map { |profile, index| leg_session(profile, "sip-call-id-#{index}") }

      profiles.each_with_index do |profile, index|
        expect(ActionCable.server).to have_received(:broadcast).with(
          profile.user.pubsub_token,
          hash_including(event: 'voice_call.incoming',
                         data: hash_including(call_sid: sessions[index].external_call_ref, logical_call_key: logical_key(sessions.first)))
        ).once
      end
    end

    it 'keeps a later call of the same client apart' do
      account.telephony_call_sessions.find_each { |session| session.update!(created_at: 1.minute.ago, status: 'no_answer') }

      report_leg(profiles.first, 'sip-call-id-next')

      next_session = leg_session(profiles.first, 'sip-call-id-next')
      expect(logical_key(next_session)).not_to eq(logical_key(leg_session(profiles.first, 'sip-call-id-0')))
    end

    it 'keeps a second call of the same client to the same operator apart' do
      report_leg(profiles.first, 'sip-call-id-repeat')

      expect(logical_key(leg_session(profiles.first, 'sip-call-id-repeat')))
        .not_to eq(logical_key(leg_session(profiles.first, 'sip-call-id-0')))
    end

    it 'keeps another client who calls at the same time apart' do
      report_leg(profiles.first, 'sip-call-id-other-client', from: '+70000000002')

      expect(logical_key(leg_session(profiles.first, 'sip-call-id-other-client')))
        .not_to eq(logical_key(leg_session(profiles.first, 'sip-call-id-0')))
    end
  end

  describe 'a leg that arrives after the caller already has a conversation' do
    it 'still joins the logical call of the leg that was reported first' do
      report_leg(profiles.first, 'sip-call-id-0')
      contact = create(:contact, account: account, phone_number: caller_number)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: channel.inbox, source_id: caller_number)
      create(:conversation, account: account, inbox: channel.inbox, contact: contact, contact_inbox: contact_inbox)

      report_leg(profiles.second, 'sip-call-id-1')

      first = leg_session(profiles.first, 'sip-call-id-0')
      second = leg_session(profiles.second, 'sip-call-id-1')
      expect(logical_key(second)).to eq(logical_key(first))
      expect(second.logical_group_sessions).to contain_exactly(first, second)
    end
  end

  # The caller/time bridge lookup is kept for what is not a browser leg: a leg
  # reported by the PBX side (janus-server, AI or provider) of the same call is
  # still part of the logical call, and a claim closes it with the others.
  describe 'a server-side leg of the same call that was reported first' do
    let(:server_leg_ref) { 'beeline:janus-server:ai:1' }
    let!(:server_leg) do
      # The first report (another caller) is what creates the number binding of the channel.
      report_leg(profiles.third, 'sip-call-id-other-caller', from: '+70000000009')
      create(
        :telephony_call_session,
        account: account, inbox: channel.inbox, conversation: nil, contact: nil,
        number_binding: account.telephony_call_sessions.last.number_binding, provider: 'beeline', direction: 'inbound',
        status: 'ringing', external_call_ref: server_leg_ref, from_number: caller_number, to_number: voice_phone_number,
        created_at: 5.seconds.ago
      )
    end

    it 'bridges a browser leg into the logical call of the server leg' do
      report_leg(profiles.first, 'sip-call-id-0')

      session = leg_session(profiles.first, 'sip-call-id-0')
      expect(session.metadata.dig('metadata', 'logical_call_group_ref')).to eq(server_leg_ref)
      expect(session.logical_group_sessions).to include(server_leg)
    end

    it 'keeps the legs of the other operators in the same logical call' do
      report_leg(profiles.first, 'sip-call-id-0')
      report_leg(profiles.second, 'sip-call-id-1')

      sessions = [leg_session(profiles.first, 'sip-call-id-0'), leg_session(profiles.second, 'sip-call-id-1')]
      expect(sessions.map { |session| session.metadata.dig('metadata', 'logical_call_group_ref') }.uniq).to eq([server_leg_ref])
      expect(sessions.first.logical_group_sessions).to include(server_leg, *sessions)
    end
  end
end
