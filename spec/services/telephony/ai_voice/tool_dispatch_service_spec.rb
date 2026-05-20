require 'rails_helper'

RSpec.describe Telephony::AiVoice::ToolDispatchService do
  describe '#perform end_call' do
    let(:account) { create(:account) }
    let(:provider) { double('provider', terminate_call: true) }
    let(:media_client) { instance_double(Whatsapp::MediaServerClient, terminate_session: true) }
    let(:whatsapp_call) do
      create(
        :call,
        account: account,
        status: 'in_progress',
        provider_call_id: 'wacid.IhggMDBENkUxMUQ3QTNGMzZGMjE0QjVBMTA0QUYwNzM0MjUcGAs3NzA4MDA4NzQyMRUCABUIAA==',
        media_session_id: 'sess_20260520062333_1'
      )
    end
    let(:call_session) do
      create(
        :telephony_call_session,
        account: account,
        conversation: whatsapp_call.conversation,
        inbox: whatsapp_call.inbox,
        contact: whatsapp_call.contact,
        number_binding: nil,
        provider: 'whatsapp_cloud',
        external_call_ref: "whatsapp:#{whatsapp_call.provider_call_id}",
        status: 'in_progress',
        metadata: {
          'ai_voice' => {
            'transport' => 'whatsapp_cloud',
            'media_session_id' => whatsapp_call.media_session_id
          },
          'whatsapp_cloud' => {
            'provider_call_id' => whatsapp_call.provider_call_id
          }
        }
      )
    end

    before do
      allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(ActionCable.server).to receive(:broadcast)
    end

    it 'terminates the WhatsApp provider call and media-server session, not just local UI state' do
      result = described_class.new(
        tool_name: 'end_call',
        payload: {
          account_id: account.id,
          call_ref: call_session.external_call_ref,
          arguments: {
            ended_by: 'user',
            reason: 'user requested to end the call'
          }
        }
      ).perform

      expect(result).to include(action: 'end_call', status: 'completed', transport_terminate_requested: true)
      expect(provider).to have_received(:terminate_call).with(whatsapp_call.provider_call_id).once
      expect(media_client).to have_received(:terminate_session).with(whatsapp_call.media_session_id).once
      expect(call_session.reload).to have_attributes(
        status: 'completed',
        ended_by: 'user',
        end_reason: 'user requested to end the call'
      )
      expect(whatsapp_call.reload.status).to eq('completed')
    end

    it 'does not terminate an unrelated WhatsApp call when a non-WhatsApp call ref collides' do
      unrelated_provider_call_id = 'shared-call-ref-1'
      unrelated_whatsapp_call = create(
        :call,
        account: account,
        status: 'in_progress',
        provider_call_id: unrelated_provider_call_id,
        media_session_id: 'unrelated-media-session'
      )
      fonoster_session = create(
        :telephony_call_session,
        account: account,
        conversation: create(:conversation, account: account),
        provider: 'fonoster',
        external_call_ref: unrelated_provider_call_id,
        status: 'in_progress',
        metadata: {}
      )

      result = described_class.new(
        tool_name: 'end_call',
        payload: {
          account_id: account.id,
          call_ref: fonoster_session.external_call_ref,
          arguments: { reason: 'caller requested hangup' }
        }
      ).perform

      expect(result).to include(action: 'end_call', status: 'completed', transport_terminate_requested: false)
      expect(provider).not_to have_received(:terminate_call)
      expect(media_client).not_to have_received(:terminate_session)
      expect(fonoster_session.reload).to have_attributes(status: 'completed', end_reason: 'caller requested hangup')
      expect(unrelated_whatsapp_call.reload.status).to eq('in_progress')
    end
  end
end
