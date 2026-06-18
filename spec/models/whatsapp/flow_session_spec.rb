require 'rails_helper'

RSpec.describe Whatsapp::FlowSession do
  describe 'token metadata' do
    it 'stores a digest and prefix for lookup without requiring raw token after send' do
      channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      flow = create(:whatsapp_flow, account: channel.account, inbox: channel.inbox)
      session = create(:whatsapp_flow_session, flow: flow)
      token = session.token

      expect(session.token_digest).to eq(described_class.digest_token(token))
      expect(session.token_prefix).to eq(described_class.prefix_token(token))
      expect(described_class.find_by_token(token, account_id: session.account_id, inbox_id: session.inbox_id)).to eq(session)

      conversation = create(:conversation, account: session.account, inbox: session.inbox)
      message = create(:message, :bot_message, account: session.account, conversation: conversation, inbox: session.inbox)
      session.mark_sent!(message: message, request_payload: { flow_id: session.flow.provider_flow_id })

      expect(session.reload.token).to be_nil
      expect(session.token_digest).to eq(described_class.digest_token(token))
      expect(described_class.find_by_token(token, account_id: session.account_id, inbox_id: session.inbox_id)).to eq(session)
    end
  end
end
