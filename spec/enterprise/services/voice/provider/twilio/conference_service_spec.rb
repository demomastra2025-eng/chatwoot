require 'rails_helper'

describe Voice::Provider::Twilio::ConferenceService do
  let(:account) { create(:account) }
  let(:channel) { create(:channel_voice, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: channel.inbox) }
  let(:twilio_client) { instance_double(Twilio::REST::Client) }
  let(:service) { described_class.new(conversation: conversation, twilio_client: twilio_client) }
  let(:webhook_service) { instance_double(Twilio::VoiceWebhookSetupService, perform: true) }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new).and_return(webhook_service)
  end

  describe '#ensure_conference_sid' do
    it 'returns and persists the deterministic conference name for the requested call' do
      expected_name = Voice::Conference::Name.for(conversation, call_ref: 'CALL123')

      expect(service.ensure_conference_sid(call_ref: 'CALL123')).to eq(expected_name)
      expect(conversation.reload.additional_attributes['conference_sid']).to eq(expected_name)
    end

    it 'replaces the previous call conference when the persistent conversation is reused' do
      previous_name = Voice::Conference::Name.for(conversation, call_ref: 'CALL-A')
      current_name = Voice::Conference::Name.for(conversation, call_ref: 'CALL-B')
      conversation.update!(additional_attributes: { 'conference_sid' => previous_name })

      sid = service.ensure_conference_sid(call_ref: 'CALL-B')

      expect(sid).to eq(current_name)
      expect(conversation.reload.additional_attributes['conference_sid']).to eq(current_name)
    end
  end

  describe '#mark_agent_joined' do
    it 'stores agent join metadata' do
      agent = create(:user, account: account)

      service.mark_agent_joined(user: agent)

      attrs = conversation.reload.additional_attributes
      expect(attrs['agent_joined']).to be true
      expect(attrs['joined_by']['id']).to eq(agent.id)
    end
  end

  describe '#end_conference' do
    it 'completes in-progress conferences' do
      conferences_proxy = instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceList)
      conf_instance = instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceInstance, sid: 'CF123')
      conf_context = instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceInstance)

      allow(twilio_client).to receive(:conferences).with(no_args).and_return(conferences_proxy)
      allow(conferences_proxy).to receive(:list).and_return([conf_instance])
      allow(twilio_client).to receive(:conferences).with('CF123').and_return(conf_context)
      allow(conf_context).to receive(:update).with(status: 'completed')

      service.end_conference(call_ref: 'CALL123')

      expect(conf_context).to have_received(:update).with(status: 'completed')
    end

    it 'targets a stale call conference by call_ref instead of the persistent conversation current conference' do
      stale_name = Voice::Conference::Name.for(conversation, call_ref: 'CALL-A')
      current_name = Voice::Conference::Name.for(conversation, call_ref: 'CALL-B')
      conversation.update!(additional_attributes: { 'conference_sid' => current_name, 'telephony_call_ref' => 'CALL-B' })
      conferences_proxy = instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceList)

      allow(twilio_client).to receive(:conferences).with(no_args).and_return(conferences_proxy)
      allow(conferences_proxy).to receive(:list).and_return([])

      service.end_conference(call_ref: 'CALL-A')

      expect(conferences_proxy).to have_received(:list).with(friendly_name: stale_name, status: 'in-progress')
      expect(conferences_proxy).not_to have_received(:list).with(friendly_name: current_name, status: 'in-progress')
    end
  end
end
