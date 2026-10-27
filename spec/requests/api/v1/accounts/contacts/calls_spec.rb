# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Contact call API', type: :request do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:headers) { agent.create_new_auth_token }
  let(:channel) { create(:channel_voice, account: account, phone_number: '+15551230000') }
  let(:voice_inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account, phone_number: '+15550001111') }
  let(:call_sid) { 'CA1234567890abcdef' }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(8)}"))
    create(:inbox_member, user: agent, inbox: voice_inbox)
    allow_any_instance_of(Channel::Voice).to receive(:initiate_call).and_return({ call_sid: call_sid }) # rubocop:disable RSpec/AnyInstance
  end

  describe 'POST /api/v1/accounts/:account_id/contacts/:id/call' do
    it 'starts the dialog of a person at the call and answers with its thread', :aggregate_failures do
      expect do
        post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/call", params: { inbox_id: voice_inbox.id }, headers: headers, as: :json
      end.to change(Conversation, :count).by(1).and change(CommunicationThread, :count).by(1)

      expect(response).to have_http_status(:success)
      conversation = Conversation.last
      expect(response.parsed_body).to include(
        'conversation_id' => conversation.display_id,
        'communication_thread_id' => conversation.communication_thread.display_id,
        'call_sid' => call_sid
      )
      expect(conversation.assignee).to eq(agent)
    end

    it 'leaves nothing behind when the call is refused', :aggregate_failures do
      allow_any_instance_of(Channel::Voice).to receive(:initiate_call).and_raise(ArgumentError, 'provider refused') # rubocop:disable RSpec/AnyInstance

      post "/api/v1/accounts/#{account.id}/contacts/#{contact.id}/call", params: { inbox_id: voice_inbox.id }, headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect([Conversation.count, CommunicationThread.count, Message.count]).to eq([0, 0, 0])
    end
  end
end
