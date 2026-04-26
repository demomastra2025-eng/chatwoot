require 'rails_helper'

RSpec.describe Campaigns::CaptainGeneratedMessageService do
  describe '#perform' do
    let(:account) { create(:account) }
    let(:email_channel) { create(:channel_email, account: account) }
    let(:inbox) { email_channel.inbox }
    let(:contact) { create(:contact, account: account, email: 'customer@example.com') }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'customer@example.com') }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    it 'uses the assistant fixed on the campaign even if the active inbox assistant changes before execution' do
      fixed_assistant = create(:captain_assistant, account: account, name: 'Fixed Campaign AI')
      active_assistant = create(:captain_assistant, account: account, name: 'New Inbox AI')
      captain_inbox = create(:captain_inbox, inbox: inbox, captain_assistant: fixed_assistant)
      campaign = create(
        :campaign,
        account: account,
        inbox: inbox,
        text_mode: :agent,
        message: '',
        instructions: 'Write a short follow-up',
        captain_assistant: fixed_assistant
      )
      captain_inbox.update!(captain_assistant: active_assistant)
      runner = instance_double(Captain::Assistant::AgentRunnerService, generate_response: { response: 'Fixed assistant message' })

      allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(runner)
      allow(Captain::OpenAiMessageBuilderService).to receive(:new).and_call_original

      result = described_class.new(campaign: campaign, conversation: conversation).perform

      expect(result[:assistant]).to eq(fixed_assistant)
      expect(result[:content]).to eq('Fixed assistant message')
      expect(Captain::Assistant::AgentRunnerService).to have_received(:new).with(
        hash_including(
          assistant: have_attributes(name: 'Fixed Campaign AI'),
          conversation: conversation,
          source: 'campaign_agent'
        )
      )
    end
  end
end
