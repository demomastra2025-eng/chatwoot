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
end
