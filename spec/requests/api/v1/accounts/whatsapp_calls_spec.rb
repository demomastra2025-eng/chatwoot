require 'rails_helper'

RSpec.describe 'WhatsApp Calls API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:call) { create(:call, account: account, status: 'in_progress', media_session_id: 'session-1') }
  let(:media_client) { instance_double(Whatsapp::MediaServerClient) }
  let(:path) { "/api/v1/accounts/#{account.id}/whatsapp_calls/#{call.id}/play_audio" }

  before do
    Current.suppress_runtime_events = true
    Conversation.skip_callback(:create, :before, :determine_conversation_status)
    Conversation.skip_callback(:commit, :after, :notify_conversation_creation)
    account.enable_features!('whatsapp_call')
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
  end

  after do
    Conversation.set_callback(:commit, :after, :notify_conversation_creation, on: :create)
    Conversation.set_callback(:create, :before, :determine_conversation_status)
    Current.suppress_runtime_events = nil
  end

  describe 'POST /play_audio' do
    it 'rejects traversal audio paths before calling the media server' do
      expect(media_client).not_to receive(:inject_audio)

      post path,
           params: { file_path: '../secret.ogg' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('Invalid file_path')
    end

    it 'passes only normalized relative ogg assets to the media server' do
      Dir.mktmpdir do |audio_root|
        FileUtils.mkdir_p(File.join(audio_root, 'prompts'))
        File.binwrite(File.join(audio_root, 'prompts', 'welcome.ogg'), 'ogg')

        expect(media_client).to receive(:inject_audio).with(
          'session-1',
          file_path: 'prompts/welcome.ogg',
          mode: 'mix',
          loop: true
        ).and_return({ 'id' => 'inj-1' })

        with_modified_env MEDIA_SERVER_AUDIO_ASSETS_ROOT: audio_root do
          post path,
               params: { file_path: 'prompts/../prompts/welcome.ogg', mode: 'mix', loop: true },
               headers: headers,
               as: :json
        end

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['injection_id']).to eq('inj-1')
      end
    end
  end
end
