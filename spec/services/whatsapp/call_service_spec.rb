require 'rails_helper'

RSpec.describe Whatsapp::CallService do
  describe '#terminate' do
    let(:account) { create(:account) }
    let(:agent) { create(:user, account: account) }
    let(:call) { create(:call, account: account, status: 'in_progress', media_session_id: 'session-1') }
    let(:provider) { double('provider', terminate_call: true) }
    let(:media_client) { instance_double(Whatsapp::MediaServerClient) }

    before do
      Current.suppress_runtime_events = true
      Conversation.skip_callback(:create, :before, :determine_conversation_status)
      Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
      allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
      allow(Whatsapp::CallMessageBuilder).to receive(:update_status!)
      allow(ActionCable.server).to receive(:broadcast)
      allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
      allow(Whatsapp::CallRecordingFetchJob).to receive(:perform_later)
    end

    after do
      Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
      Conversation.set_callback(:create, :before, :determine_conversation_status)
      Current.suppress_runtime_events = nil
    end

    it 'marks the call terminal and asks Meta to terminate before closing media locally' do
      expect(provider).to receive(:terminate_call).with(call.provider_call_id).ordered do
        expect(call.reload.status).to eq('completed')
        expect(call.end_reason).to eq('agent_terminated')
        true
      end
      expect(media_client).to receive(:terminate_session).with('session-1').ordered

      described_class.new(call: call, agent: agent).terminate

      expect(call.reload.status).to eq('completed')
      expect(Whatsapp::CallRecordingFetchJob).to have_received(:perform_later).with(call.id)
      expect(ActionCable.server).to have_received(:broadcast).with(
        "account_#{account.id}",
        hash_including(event: 'whatsapp_call.ended', data: hash_including(account_id: account.id, call_id: call.provider_call_id))
      )
    end

    it 'is idempotent for already terminal calls' do
      call.update!(status: 'completed')

      expect(media_client).not_to receive(:terminate_session)
      expect(provider).not_to receive(:terminate_call)

      described_class.new(call: call, agent: agent).terminate
    end

    it 'releases agent reservation and terminates orphan media session when provider pre-accept fails' do
      call.update!(status: 'ringing', accepted_by_agent_id: nil, meta: { 'sdp_offer' => 'meta-offer', 'ice_servers' => [] })

      expect(media_client).to receive(:create_session).and_return({ 'session_id' => 'media-1', 'meta_sdp_answer' => 'answer' })
      expect(media_client).to receive(:generate_agent_offer).with('media-1').and_return({ 'sdp_offer' => 'agent-offer', 'ice_servers' => [] })
      expect(provider).to receive(:pre_accept_call).with(call.provider_call_id, 'answer').and_return(false)
      expect(provider).not_to receive(:accept_call)
      expect(provider).not_to receive(:terminate_call)
      expect(media_client).to receive(:terminate_session).with('media-1')

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        expect { described_class.new(call: call, agent: agent).accept }.to raise_error(Whatsapp::CallErrors::NotRinging)
      end

      expect(call.reload.status).to eq('ringing')
      expect(call.accepted_by_agent_id).to be_nil
    end

    it 'accepts a media-server call that was prepared when the inbound connect arrived' do
      call.update!(
        status: 'ringing',
        accepted_by_agent_id: nil,
        media_session_id: 'prepared-media-1',
        meta: {
          'sdp_offer' => 'meta-offer',
          'ice_servers' => [],
          'media_sdp_answer' => 'prepared-meta-answer',
          'agent_offer' => { 'sdp_offer' => 'prepared-agent-offer', 'ice_servers' => [] },
          'agent_offer_generated_at' => 1_776_000_000
        }
      )

      expect(media_client).not_to receive(:create_session)
      expect(media_client).not_to receive(:generate_agent_offer)
      expect(provider).to receive(:pre_accept_call).with(call.provider_call_id, 'prepared-meta-answer').and_return(true)
      expect(provider).to receive(:accept_call).with(call.provider_call_id, 'prepared-meta-answer').and_return(true)

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        service = described_class.new(call: call, agent: agent)
        service.accept
        expect(service.agent_offer).to eq('sdp_offer' => 'prepared-agent-offer', 'ice_servers' => [])
      end

      expect(call.reload.status).to eq('in_progress')
      expect(call.media_session_id).to eq('prepared-media-1')
      expect(call.accepted_by_agent_id).to eq(agent.id)
    end

    it 'does not let another agent steal a reserved media-server call' do
      other_agent = create(:user, account: account)
      call.update!(status: 'ringing', accepted_by_agent_id: other_agent.id, meta: { 'sdp_offer' => 'meta-offer', 'ice_servers' => [] })

      expect(media_client).not_to receive(:create_session)
      expect(provider).not_to receive(:pre_accept_call)
      expect(provider).not_to receive(:accept_call)

      with_modified_env(MEDIA_SERVER_URL: 'http://media-server:4000', MEDIA_SERVER_AUTH_TOKEN: 'secret') do
        expect { described_class.new(call: call, agent: agent).accept }.to raise_error(Whatsapp::CallErrors::AlreadyAccepted)
      end

      expect(call.reload.accepted_by_agent_id).to eq(other_agent.id)
      expect(call.status).to eq('ringing')
    end
  end
end
