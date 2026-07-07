require 'rails_helper'

RSpec.describe Telephony::AiVoice::JanusSipAttachService do
  describe '#perform' do
    it 'does not attach Janus AI calls with a human SIP profile' do
      account = create(:account)
      inbox = create(:channel_voice, :sipuni, account: account).inbox
      number_binding = inbox.telephony_number_binding
      call_session = create(
        :telephony_call_session,
        account: account,
        inbox: inbox,
        number_binding: number_binding,
        provider: 'sipuni',
        direction: 'inbound',
        external_call_ref: 'sipuni:janus:human-profile'
      )
      sip_profile = create(
        :telephony_sip_profile,
        account: account,
        inbox: inbox,
        user: create(:user, account: account),
        availability_mode: 'browser_webphone',
        status: 'active'
      )
      runtime_client = instance_double(Telephony::AiVoice::JanusSipRuntimeClient, enabled?: true, attach_call: {})

      described_class.new(
        call_session: call_session,
        routing_decision: { action: 'ai', reason: 'ai_route' },
        sip_profile: sip_profile,
        params: {},
        runtime_client: runtime_client
      ).perform

      expect(runtime_client).not_to have_received(:enabled?)
      expect(runtime_client).not_to have_received(:attach_call)
      expect(call_session.reload.metadata.dig('ai_voice', 'state')).to eq('skipped')
      expect(call_session.metadata.dig('ai_voice', 'reason')).to eq('sip_profile_not_voice_agent')
    end
  end
end
