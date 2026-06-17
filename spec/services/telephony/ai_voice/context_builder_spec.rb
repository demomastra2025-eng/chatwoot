require 'rails_helper'

RSpec.describe Telephony::AiVoice::ContextBuilder do
  describe '#captain_runtime_state_for_prompt' do
    let(:account) { create(:account, captain_runtime: { 'assistant_thinking_effort' => 'low' }) }
    let(:whatsapp_channel) do
      create(
        :channel_whatsapp,
        account: account,
        provider: 'whatsapp_cloud',
        sync_templates: false,
        validate_provider_config: false
      )
    end
    let(:inbox) { whatsapp_channel.inbox }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:assistant) { create(:captain_assistant, account: account) }
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: conversation,
        inbox: inbox,
        number_binding: nil,
        external_call_ref: 'whatsapp:wacid-test-call'
      )
    end

    before do
      create(:captain_inbox, inbox: inbox, captain_assistant: assistant)
    end

    it 'uses the lightweight runtime preferences instead of full captain preferences' do
      builder = described_class.new(
        params: {
          'call_ref' => call_session.external_call_ref,
          'account_id' => account.id
        }
      )
      resolved_account = builder.send(:account)

      expect(resolved_account).not_to receive(:captain_preferences)
      expect(resolved_account).to receive(:captain_runtime_preferences).and_call_original

      state = builder.send(:captain_runtime_state_for_prompt)

      expect(state[:captain_runtime]['assistant_thinking_effort']).to eq('low')
    end
  end
end
