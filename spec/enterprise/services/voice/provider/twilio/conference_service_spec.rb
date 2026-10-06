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
    it 'returns existing sid if present' do
      conversation.update!(additional_attributes: { 'conference_sid' => 'CF_EXISTING' })

      expect(service.ensure_conference_sid).to eq('CF_EXISTING')
    end

    it 'sets and returns generated sid when missing' do
      allow(Voice::Conference::Name).to receive(:for).and_return('CF_GEN')

      sid = service.ensure_conference_sid

      expect(sid).to eq('CF_GEN')
      expect(conversation.reload.additional_attributes['conference_sid']).to eq('CF_GEN')
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

  describe '#mark_agent_joined with an owner' do
    let(:owner) { create(:user, account: account) }
    let(:colleague) { create(:user, account: account) }

    before do
      conversation.update!(additional_attributes: { 'call_status' => 'in_progress', 'joined_by' => { 'id' => owner.id, 'name' => owner.name } })
    end

    it 'refuses to replace the owner of a live call' do
      expect { service.mark_agent_joined(user: colleague) }.to raise_error(described_class::NotCallOwner)

      expect(conversation.reload.additional_attributes.dig('joined_by', 'id')).to eq(owner.id)
    end

    it 'decides on the freshly locked row, not on the object it was built with' do
      unowned = create(:conversation, account: account, inbox: channel.inbox)
      stale_service = described_class.new(conversation: Conversation.find(unowned.id))
      unowned.update!(additional_attributes: { 'call_status' => 'in_progress', 'joined_by' => { 'id' => owner.id, 'name' => owner.name } })

      expect { stale_service.mark_agent_joined(user: colleague) }.to raise_error(described_class::NotCallOwner)
      expect(unowned.reload.additional_attributes.dig('joined_by', 'id')).to eq(owner.id)
    end

    it 'lets the owner join again and lets anybody join once the call is over' do
      service.mark_agent_joined(user: owner)
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('call_status' => 'completed'))
      service.mark_agent_joined(user: colleague)

      expect(conversation.reload.additional_attributes.dig('joined_by', 'id')).to eq(colleague.id)
    end
  end

  describe '#end_conference with a user' do
    let(:owner) { create(:user, account: account) }
    let(:colleague) { create(:user, account: account) }

    before do
      conversation.update!(additional_attributes: { 'joined_by' => { 'id' => owner.id, 'name' => owner.name } })
    end

    it 'refuses a user that is not the owner without calling Twilio' do
      expect(twilio_client).not_to receive(:conferences)

      expect { service.end_conference(user: colleague) }.to raise_error(described_class::NotCallOwner)
    end

    it 'checks the owner on the freshly locked row' do
      stale_service = described_class.new(conversation: Conversation.find(conversation.id), twilio_client: twilio_client)
      conversation.update!(additional_attributes: { 'joined_by' => { 'id' => colleague.id, 'name' => colleague.name } })
      expect(twilio_client).not_to receive(:conferences)

      expect { stale_service.end_conference(user: owner) }.to raise_error(described_class::NotCallOwner)
    end

    it 'lets the owner end the conference' do
      conferences_proxy = instance_double(Twilio::REST::Api::V2010::AccountContext::ConferenceList, list: [])
      allow(twilio_client).to receive(:conferences).with(no_args).and_return(conferences_proxy)

      expect { service.end_conference(user: owner) }.not_to raise_error
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

      service.end_conference

      expect(conf_context).to have_received(:update).with(status: 'completed')
    end
  end
end
